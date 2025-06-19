import subprocess


RESULT_FLAG = "### RESULT ###"


def run_command(command: list[str]) -> list[str]:
    """Runs command and return list of lines after RESULT flag found in stdout"""

    process = subprocess.Popen(command, stdout=subprocess.PIPE)

    save_output = False
    output = []
    # Read the output in real-time and flush the buffer
    for line in process.stdout:
        # Save stdout after encountering RESULT_FLAG
        if save_output:
            output.append(line.decode().strip())
        if line.decode().strip() == RESULT_FLAG:
            save_output = True
        print(line.decode().strip(), flush=True)

    return output


def parse_key_val_output(output: list[str]) -> dict:
    """Parse output in key-value format, e.g. ['BUNDLE_IMAGE: registry.rh.io...']"""
    parsed = {}
    for line in output:
        k, v = line.split(": ")
        parsed[k] = v
    return parsed


def convert_tag_to_sha(img: str) -> str:
    """Converts image URL with tag to image URL with sha"""
    if "@sha256:" not in img:
        print("Converting tag to sha...")
        sha = run_command(["bash", "scripts/convert_to_sha.sh", img])
        if not sha:
            print(f"Could not get sha of from: {img}")
            exit(1)
        return f"{img.split(':')[0]}@{sha[0]}"
    return img
