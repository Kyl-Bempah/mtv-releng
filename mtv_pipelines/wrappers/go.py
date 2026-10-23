import json
import logging
import os
import subprocess

logger = logging.getLogger(__name__)


class GoCommandError(RuntimeError):
    """A go / govulncheck command exited non-zero."""


def decode_json_stream(text: str) -> list[dict]:
    """Split the concatenated JSON objects `go list -json` emits."""
    decoder = json.JSONDecoder()
    objects, idx = [], 0
    while idx < len(text):
        if text[idx].isspace():
            idx += 1
            continue
        obj, idx = decoder.raw_decode(text, idx)
        objects.append(obj)
    return objects


class Go:
    """Runs go tooling inside one module directory.

    Module-graph commands (get, tidy, list) use -mod=mod; only builds use the
    vendor directory, matching how the downstream Containerfiles build.
    """

    def __init__(self, module_dir: str, timeout: int, vendor: bool = False):
        self.module_dir = module_dir
        self.timeout = timeout
        self.vendor = vendor

    def _run(self, args: list[str], goflags: str) -> str:
        env = {**os.environ, "GOFLAGS": goflags, "GOWORK": "off"}
        logger.info(f"[{self.module_dir}] {' '.join(args)}")
        try:
            result = subprocess.run(
                args,
                cwd=self.module_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired as e:
            raise GoCommandError(f"{' '.join(args)} timed out") from e
        if result.returncode != 0:
            raise GoCommandError(
                result.stderr.strip() or result.stdout.strip()
            )
        return result.stdout

    def _mod(self, *args: str) -> str:
        return self._run(["go", *args], "-mod=mod")

    def build(self, target: str, out: str = "") -> None:
        """Build like Konflux: from vendor/, or read-only go.mod/go.sum."""
        mod = "-mod=vendor" if self.vendor else "-mod=readonly"
        if not out and not target.startswith("./"):
            out = os.devnull
        self._run(
            ["go", "build", *(["-o", out] if out else []), target],
            f"{mod} -tags=strictfipsruntime",
        )

    def fill_sums(self, target: str) -> None:
        """Record every go.sum entry building *target* needs (no tidy)."""
        self._run(
            ["go", "build", "-o", os.devnull, target],
            "-mod=mod -tags=strictfipsruntime",
        )

    def edit_json(self) -> dict:
        return json.loads(self._mod("mod", "edit", "-json"))

    def get(self, specs: list[str]) -> None:
        self._mod("get", *specs)

    def tidy(self) -> None:
        self._mod("mod", "tidy")

    def vendor_modules(self) -> None:
        self._mod("mod", "vendor")

    def set_toolchain(self, toolchain: str) -> None:
        self._mod("mod", "edit", f"-toolchain={toolchain or 'none'}")

    def list_updates(self) -> list[dict]:
        return decode_json_stream(
            self._mod("list", "-m", "-u", "-json", "all")
        )

    def versions(self, path: str) -> list[str]:
        out = self._mod("list", "-m", "-versions", path).split()
        return out[1:]  # first field is the module path

    def govulncheck(self, binary: str = "") -> list[dict]:
        """Module-level vulnerability findings for this module.

        With *binary*, scan that built executable instead of the module's
        packages; for a module that only pins a tool (.konflux/validation
        builds OPA and has no Go files) that's the only thing to scan.
        """
        env = {**os.environ, "GOFLAGS": "-mod=mod", "GOWORK": "off"}
        args = ["govulncheck", "-scan", "module", "-format", "json"]
        if binary:
            args[1:1] = ["-mode", "binary"]
            args.append(binary)
        logger.info(f"[{self.module_dir}] {' '.join(args)}")
        result = subprocess.run(
            args,
            cwd=self.module_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=self.timeout,
        )
        # govulncheck exits 3 when it finds vulnerabilities; that's success.
        if result.returncode not in (0, 3):
            raise GoCommandError(result.stderr.strip())
        return decode_json_stream(result.stdout)
