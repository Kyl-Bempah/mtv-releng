import pytest
from tasks.branching import (
    mtv_version_parts,
    render_release_conf,
    transform_tekton_content,
)
from tasks.konflux_stream import (
    build_btrfs_pds_block,
    transform_prod_stream,
    transform_rpa,
)


class TestMtvVersionParts:
    def test_splits_xy_and_version_name(self):
        assert mtv_version_parts("2.11.0") == ("2.11", "2-11")

    def test_two_digit_minor(self):
        assert mtv_version_parts("2.12.6") == ("2.12", "2-12")

    def test_invalid_version_raises(self):
        with pytest.raises(ValueError):
            mtv_version_parts("2-11")


class TestRenderReleaseConf:
    def test_forklift_has_mtv_version_and_ocp(self):
        out = render_release_conf(
            "forklift",
            version="2.11.0",
            release="v2.11",
            channel="release-v2.11",
            default_channel="release-v2.11",
            registry="migration-toolkit-virtualization",
            ocp_versions="v4.17-v4.19",
        )
        assert "MTV_VERSION=2.11.0" in out
        assert "CPE=2.11" in out
        assert "OCP_VERSIONS=v4.17-v4.19" in out
        assert out.endswith("\n")

    def test_console_plugin_uses_rversion_and_no_ocp(self):
        out = render_release_conf(
            "forklift-console-plugin",
            version="2.11.0",
            release="v2.11",
            channel="c",
            default_channel="d",
            registry="r",
            ocp_versions="ignored",
        )
        assert "RVERSION=2.11.0" in out
        assert "MTV_VERSION" not in out
        assert "OCP_VERSIONS" not in out

    def test_must_gather_uses_plain_version(self):
        out = render_release_conf(
            "forklift-must-gather",
            version="2.11.0",
            release="v2.11",
            channel="c",
            default_channel="d",
            registry="r",
            ocp_versions="",
        )
        assert "\nVERSION=2.11.0" in out
        assert "OCP_VERSIONS" not in out

    def test_unknown_origin_raises(self):
        with pytest.raises(ValueError):
            render_release_conf(
                "forklift-int",
                version="2.11.0",
                release="v2.11",
                channel="c",
                default_channel="d",
                registry="r",
                ocp_versions="",
            )


class TestTransformTektonContent:
    def test_retargets_branch_and_stream(self):
        src = 'on-cel: "main"\napp: forklift-operator-dev-preview\n'
        out = transform_tekton_content(src, "2-11", "2.11", "dev-preview")
        assert '"release-2.11"' in out
        assert "forklift-operator-2-11" in out
        assert "dev-preview" not in out


class TestTransformProdStream:
    def test_full_transform(self):
        src = (
            "metadata:\n"
            "  annotations:\n"
            "    build.appstudio.openshift.io/pipeline: p\n"
            "  name: forklift-operator-dev-preview\n"
            "spec:\n"
            '  revision: "main"\n'
        )
        out = transform_prod_stream(src, "2-11", "2.11", "dev-preview")
        assert "forklift-operator-2-11" in out
        assert 'revision: "release-2.11"' in out
        assert (
            "    build.appstudio.openshift.io/request: configure-pac-no-mr" in out
        )
        # annotation is inserted right after the pipeline line
        lines = out.split("\n")
        i = lines.index("    build.appstudio.openshift.io/pipeline: p")
        assert lines[i + 1].strip() == (
            "build.appstudio.openshift.io/request: configure-pac-no-mr"
        )


class TestBuildBtrfsPdsBlock:
    def test_contains_version_fields(self):
        out = build_btrfs_pds_block("2-11", "2.11")
        assert "forklift-operator-int-pds-2-11" in out
        assert 'value: "2-11"' in out
        assert 'value: "release-2.11"' in out
        assert out.startswith("---\n")
        assert out.endswith("\n")


class TestTransformRpa:
    def test_retargets_version_registry_and_product_version(self):
        src = (
            "name: forklift-operator-rpa-stage-dev-preview-x\n"
            "registry: mtv-candidate\n"
            '      product_version: "9.99"\n'
        )
        out = transform_rpa(
            src, "2-11", "migration-toolkit-virtualization", "2.11",
            "dev-preview", "mtv-candidate",
        )
        assert "dev-preview" not in out
        assert "mtv-candidate" not in out
        assert "migration-toolkit-virtualization" in out
        assert '      product_version: "2.11"' in out
