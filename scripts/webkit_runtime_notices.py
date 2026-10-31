#!/usr/bin/env python3
"""Install and verify scoped notices for the owned WebKit runtime slice.

This accounts for the bundled Swift CompatibilitySpan library, preserves the
exact pinned WebCore LGPL-2 and LGPL-2.1 texts, and adds source-mapped ANGLE notices.
It does not determine per-file license applicability or close WebKit source,
notice, relinking, or distribution obligations.
"""
from __future__ import annotations

import argparse
from contextvars import ContextVar
from functools import wraps
import hashlib
import html
import importlib.util
import json
import os
import plistlib
from pathlib import Path
from pathlib import PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LICENSE_SOURCE = Path("runtime/licenses/Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt")
LICENSE_NAME = "Swift-6.4.0-Runtime-Library-Exception-LICENSE.txt"
LICENSE_SHA256 = "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55"
LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / LICENSE_NAME
WEBCORE_LGPL2_SOURCE = Path("docs/evidence/third-party/webcore/LICENSE-LGPL-2")
WEBCORE_LGPL2_NAME = "WebCore-LICENSE-LGPL-2.txt"
WEBCORE_LGPL2_SHA256 = "7555fa34bc131a75ca56d65c40cc1ea8f9515d23e353d4c15d58573a042f7805"
WEBCORE_LGPL2_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / WEBCORE_LGPL2_NAME
)
WEBCORE_LGPL21_SOURCE = Path("docs/evidence/third-party/webcore/LICENSE-LGPL-2.1")
WEBCORE_LGPL21_NAME = "WebCore-LICENSE-LGPL-2.1.txt"
WEBCORE_LGPL21_SHA256 = "f2b3bd09663381deb99721109d22b47af1213bb43007a8b56a06c6375c8050ce"
WEBCORE_LGPL21_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / WEBCORE_LGPL21_NAME
)
JSC_TRI_LICENSE_ROOT = Path("docs/evidence/third-party/official-license-texts-20261025")
JSC_COPYING_LIB_SOURCE = Path("docs/evidence/third-party/javascriptcore/COPYING.LIB")
JSC_COPYING_LIB_SHA256 = "5094ecb9c9dcd0eadc34f3c11511d9b5535063032bc150164ecd1a5d5a445547"
JSC_COPYING_LIB_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/COPYING.LIB")
JSC_COPYING_LIB_SECTION_MARKER = "## JavaScriptCore source-referenced GNU Library GPL v2 text"
JSC_COPYING_LIB_HTML_MARKER = '<section id="neantik-jsc-copying-lib-lgpl-v2-notice">'
JSC_BINJA_ATTRIBUTION_SOURCE = Path(
    "docs/evidence/third-party/javascriptcore/LICENSE-binja.txt")
JSC_BINJA_ATTRIBUTION_SHA256 = "94c095293b051622c4279153e94f8f69e6e9fd41c2d6eef07ad9ea02c30fb4c0"
JSC_BINJA_ATTRIBUTION_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/BinaryNinja/LICENSE-binja.txt")
JSC_BINJA_APACHE_SOURCE = Path(
    "docs/evidence/third-party/javascriptcore/LICENSE-APACHE-2.0.txt")
JSC_BINJA_APACHE_SHA256 = "0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594"
JSC_BINJA_APACHE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/BinaryNinja/LICENSE-APACHE-2.0.txt")
JSC_BINJA_SECTION_MARKER = "## JavaScriptCore ARM64 disassembler Binary Ninja Apache-2.0 notices"
JSC_BINJA_HTML_MARKER = '<section id="neantik-jsc-binaryninja-apache-2-notice">'
JSC_UNICODE_LICENSE_SOURCE = JSC_TRI_LICENSE_ROOT / "Unicode-License-V3.txt"
JSC_UNICODE_LICENSE_SHA256 = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
JSC_UNICODE_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/Unicode-License-V3.txt")
JSC_GENERATED_LINEAGE_SOURCE = Path(
    "docs/evidence/webkit-v20-jsc-generated-input-lineage-20261025.json")
JSC_GENERATED_LINEAGE_SHA256 = "d50c37630550bd85d2685e9ef3046b19ecac83baca18a9503dde142c25e7a9cf"
JSC_GENERATED_LINEAGE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/GeneratedInputLineage.json")
JSC_UNICODE_SECTION_MARKER = "## JavaScriptCore Unicode CaseFolding generated-input notice"
JSC_UNICODE_HTML_MARKER = '<section id="neantik-jsc-unicode-casefolding-input-notice">'
JSC_MPL11_SOURCE = JSC_TRI_LICENSE_ROOT / "MPL-1.1.txt"
JSC_MPL11_SHA256 = "f849fc26a7a99981611a3a370e83078deb617d12a45776d6c4cada4d338be469"
JSC_MPL11_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/MPL-1.1.txt")
JSC_GPL2_SOURCE = JSC_TRI_LICENSE_ROOT / "GPL-2.0.txt"
JSC_GPL2_SHA256 = "edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6"
JSC_GPL2_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/GPL-2.0.txt")
JSC_TRI_LICENSE_SECTION_MARKER = "## JavaScriptCore JSDateMath.cpp source-stated license alternatives"
JSC_TRI_LICENSE_HTML_MARKER = '<section id="neantik-jsc-jsdatemath-license-alternatives">'
JSC_HEADERLESS_BSD2_LICENSE_SOURCE = (
    Path("docs/evidence/third-party/webkit-v20-license-text-corpus")
    / "Source/WebCore/LICENSE-APPLE"
)
JSC_HEADERLESS_BSD2_LICENSE_SHA256 = "0b5d3a7cc325942567373b0ecd757d07c132e0ebd7c97bfc63f7e1a76094edb4"
JSC_HEADERLESS_BSD2_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/Apple-BSD-2-Clause.txt")
V135_JSC_HEADERLESS_BSD2_REVIEW_SHA256 = "e5096eec97de1fe998990e19d546e5ed15ea4056f007f8660699d7b5bd5f74c9"
V135_JSC_HEADERLESS_BSD2_IMAGE_SHA256 = "8e6d73e593ee32196767b35a236cffc1f172bd12f23073cdc35ef290f506ef63"
JSC_HEADERLESS_BSD2_REVIEW_SOURCE = Path(
    "docs/evidence/v438-runtime-notice-bindings/JSC-HEADERLESS-INPUTS-REVIEW-v438.json")
JSC_HEADERLESS_BSD2_REVIEW_SHA256 = "be108c5241f09319bfdfcb77bf3ac8c79189710037e2f037b22a3b63619486aa"
JSC_HEADERLESS_BSD2_ORIGINAL_REVIEW_SHA256 = "d972d9a6aabeea932a56aa96c2bc551b95294d370f98505aa80ef5e95cd46ba4"
JSC_HEADERLESS_BSD2_IMAGE_SHA256 = "fcfce29db5959a47d549b26c6e8539cc5b24ad63abec114189d3053fb9074238"
JSC_HEADERLESS_BSD2_REVIEW_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/HeaderlessInputsBSD2Review.json")
JSC_HEADERLESS_BSD2_SECTION_MARKER = "## JavaScriptCore headerless generator-input BSD-2 notice"
JSC_HEADERLESS_BSD2_HTML_MARKER = '<section id="neantik-jsc-headerless-inputs-bsd2-notice">'
V135_JSC_GENERATED_OUTPUT_MANIFEST_SHA256 = "845bd7528fa35415a53be226137daf30b2d31fce6f3d6264486f5f2a809799e4"
JSC_GENERATED_OUTPUT_MANIFEST_SOURCE = Path(
    "docs/evidence/v424-runtime-notice-bindings/JSC-GENERATED-OUTPUT-MANIFEST-v424.json")
JSC_GENERATED_OUTPUT_MANIFEST_SHA256 = "ff94dfff4461746d887323957f705296281a09ab964588434b40baa8287b3c6a"
JSC_GENERATED_OUTPUT_HEADERS_SOURCE = Path(
    "docs/evidence/third-party/webkit-v20-jsc-generated-output-notice-headers.txt")
JSC_GENERATED_OUTPUT_HEADERS_SHA256 = "eba2a7319405fa1ac2eacd09c4146aab12afac07578a617d0528d8d869d7119a"
JSC_GENERATED_OUTPUT_DESTINATION_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/JavaScriptCore/GeneratedOutputHeaders")
JSC_GENERATED_OUTPUT_SECTION_MARKER = "## JavaScriptCore generated-output copyright and license headers"
JSC_GENERATED_OUTPUT_HTML_MARKER = '<section id="neantik-jsc-generated-output-headers">'
ANGLE_LICENSE_SOURCE = Path("docs/evidence/third-party/angle/ANGLE-LICENSE-43d5b8d85e2e5eed41d7ff8a79da831bf405be6c")
ANGLE_LICENSE_NAME = "ANGLE-LICENSE.txt"
ANGLE_LICENSE_SHA256 = "bf4da21bd20bcfb5b60b7ecc67fa864a79be049e21d6178076887f178dd6c71a"
ANGLE_LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / ANGLE_LICENSE_NAME
XXHASH_LICENSE_SOURCE = Path("docs/evidence/third-party/angle/xxhash-LICENSE-e4c5da7234eca7baad9a46f0b144e49ccad2e500")
XXHASH_LICENSE_NAME = "xxHash-LICENSE.txt"
XXHASH_LICENSE_SHA256 = "6ffedbc0f7878612d2b23589f1ff2ab15633e1df7963a5d9fc750ec5500c7e7a"
XXHASH_LICENSE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses") / XXHASH_LICENSE_NAME
CHROMIUM_ANGLE_LICENSE_SOURCE = Path("docs/evidence/third-party/chromium/LICENSE-738956cca47a264e92106fdbefdc040ee7ed487d")
CHROMIUM_ANGLE_LICENSE_NAME = "Chromium-ANGLE-DEPS-LICENSE.txt"
CHROMIUM_ANGLE_LICENSE_SHA256 = "368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b"
CHROMIUM_ANGLE_LICENSE_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / CHROMIUM_ANGLE_LICENSE_NAME
)
WEBRTC_CANDIDATE_ROOT = Path(
    "docs/evidence/third-party/webkit-v20-webrtc-notices-cmake-candidate-v4"
)
WEBRTC_MANIFEST_SOURCE = WEBRTC_CANDIDATE_ROOT / "MANIFEST.json"
WEBRTC_MANIFEST_SHA256 = "513cbd53b99c2b8c5a6dd807b58c357c279e25b54b8d9d6d73dbdc9a7b55a626"
WEBRTC_IMAGE_NAME = "libwebrtc.dylib"
WEBRTC_NOTICE_ROOT = Path("Contents/Resources/NeAntikRuntimeLicenses/WebRTC")
WEBRTC_LIBWEBM_AUTHORS_SOURCE = Path(
    "docs/evidence/third-party/webkit-v20-webrtc-notice-supplements/libwebm/AUTHORS.TXT")
WEBRTC_LIBWEBM_AUTHORS_SHA256 = "3edb5f5496bfff3d6d4a62fa75fe996b814920d0d6e348c2e65c589e7ac5d177"
WEBRTC_LIBWEBM_AUTHORS_DESTINATION = WEBRTC_NOTICE_ROOT / "supplements/libwebm/AUTHORS.TXT"
RNNOISE_HEADER_SOURCE = Path("docs/evidence/third-party/webkit-rnnoise-header-supplement.txt")
RNNOISE_HEADER_SHA256 = "81e8caa1ae5813d4f71f39537eea73e41cf141de9497a7688386aa6c2b935d0b"
RNNOISE_HEADER_DESTINATION = WEBRTC_NOTICE_ROOT / "supplements/rnnoise/rnn-activations-header.txt"
LIBSRTP_HEADERS_SOURCE = Path("docs/evidence/third-party/webkit-libsrtp-header-supplement.txt")
LIBSRTP_HEADERS_SHA256 = "db280c67d1b26fb1745b026251168e09a884cc090b827c0439057ddbb8c56077"
LIBSRTP_HEADERS_DESTINATION = WEBRTC_NOTICE_ROOT / "supplements/libsrtp/source-headers.txt"
OPUS_HEADERS_SOURCE = Path("docs/evidence/third-party/webkit-opus-header-supplement.txt")
OPUS_HEADERS_SHA256 = "e2e9fad66a8f3c412fcea3ef0326de0d1458d00f883c93b9ab1fb62bb1ee1a68"
OPUS_HEADERS_DESTINATION = WEBRTC_NOTICE_ROOT / "supplements/opus/source-headers.txt"
WEBRTC_MPL2_SOURCE = Path("docs/evidence/third-party/MPL-2.0-mozilla.txt")
WEBRTC_MPL2_SHA256 = "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04"
WEBRTC_MPL2_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses/WebRTC/NeAntik-usage_exit_stub-MPL-2.0.txt")
LINKED_HEADERS_SOURCE_ROOT = Path("docs/evidence/v135-runtime-notice-bindings")
LINKED_HEADERS_MANIFEST_SOURCE = LINKED_HEADERS_SOURCE_ROOT / "LINKED-SOURCE-HEADERS-MANIFEST-v135.json"
LINKED_HEADERS_MANIFEST_SHA256 = "0f49b2e49d78d7052245d4916d52b5421097a0970ff83e1ce6c788709133eea2"
LINKED_HEADERS_DESTINATION_ROOT = Path("Contents/Resources/NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders")
DAV1D_HEADERS_SOURCE = Path("docs/evidence/third-party/webkit-dav1d-source-header-supplement.txt")
DAV1D_HEADERS_SHA256 = "a71dccabd6835d5d0f5be9cca8107f71fb97ed432f7f9e835483a95a371e5865"
DAV1D_HEADERS_DESTINATION = LINKED_HEADERS_DESTINATION_ROOT / "dav1d-source-header-supplement.txt"
LINKED_HEADERS_SECTION_MARKER = "## Exact linked JavaScriptCore, WebCore and WebKit source headers"
LINKED_HEADERS_HTML_MARKER = '<section id="neantik-webkit-linked-source-headers">'
WEBCORE_GENERATED_HEADERS_SOURCE = Path(
    "docs/evidence/third-party/webkit-v20-webcore-generated-input-headers.txt")
WEBCORE_GENERATED_HEADERS_SHA256 = "93d9ce3e3f3b35465749b4494e55633000e703551115363129fc2afd65ab6aa8"
WEBCORE_GENERATED_HEADERS_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCoreGeneratedInputHeaders.txt")
WEBCORE_GENERATED_HEADERS_SECTION_MARKER = "## WebCore generated-input source headers"
WEBCORE_GENERATED_HEADERS_HTML_MARKER = '<section id="neantik-webcore-generated-input-headers">'
WEBCORE_POPOVER_LICENSE_SOURCE = Path(
    "docs/evidence/third-party/webcore/WEBCORE-POPOVER-BSD-2-Clause.txt")
WEBCORE_POPOVER_LICENSE_SHA256 = "3c9203d778d97eda6e0433a557232f5303476b77e88fdfd0719b39c26ec9581b"
WEBCORE_POPOVER_LICENSE_TEMPLATE_SOURCE = Path(
    "docs/evidence/third-party/webkit-v20-license-text-corpus/Source/WebCore/LICENSE-APPLE")
WEBCORE_POPOVER_LICENSE_TEMPLATE_SHA256 = "0b5d3a7cc325942567373b0ecd757d07c132e0ebd7c97bfc63f7e1a76094edb4"
WEBCORE_POPOVER_REVIEW_SOURCE = Path(
    "docs/evidence/v135-runtime-notice-bindings/WEBCORE-POPOVER-REVIEW-v135.json")
WEBCORE_POPOVER_REVIEW_SHA256 = "d865038a8903b114ef6fb3858e1c750b1f2c17b75f161cad32902481b4cc7f81"
WEBCORE_POPOVER_RUNTIME_SHA256 = "2dfb23280d68b0b89bf493a16de3696a326ccf8cdb88722593998bb00bbdd6a8"
WEBCORE_POPOVER_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/PopoverCSS-BSD-2-Clause.txt")
WEBCORE_POPOVER_REVIEW_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/PopoverCSSReview.json")
WEBCORE_POPOVER_SECTION_MARKER = "## WebCore popover.css source notice"
WEBCORE_POPOVER_HTML_MARKER = '<section id="neantik-webcore-popover-css-notice">'
WEBCORE_COLORDATA_LICENSE_SOURCE = Path(
    "docs/evidence/third-party/webcore/WEBCORE-COLORDATA-BSD-2-Clause.txt")
WEBCORE_COLORDATA_LICENSE_SHA256 = "c1729f9029d1331d6ee663853411d9dd5f3fa4f2b831880fbc91743c323df401"
WEBCORE_COLORDATA_REVIEW_SOURCE = Path(
    "docs/evidence/v135-runtime-notice-bindings/WEBCORE-COLORDATA-REVIEW-v135.json")
WEBCORE_COLORDATA_REVIEW_SHA256 = "0db71a6e54737e9d88e194737fedd4ff1e6540a464c6d7f35b879d616985386e"
WEBCORE_COLORDATA_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/ColorData-BSD-2-Clause.txt")
WEBCORE_COLORDATA_REVIEW_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/ColorDataReview.json")
WEBCORE_COLORDATA_SECTION_MARKER = "## WebCore ColorData.gperf source notice"
WEBCORE_COLORDATA_HTML_MARKER = '<section id="neantik-webcore-colordata-notice">'
WEBCORE_CSS_GENERATED_APPLE_LICENSE_SOURCE = Path(
    "docs/evidence/third-party/webcore/WebCore-LICENSE-APPLE.txt")
WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256 = "0b5d3a7cc325942567373b0ecd757d07c132e0ebd7c97bfc63f7e1a76094edb4"
WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SOURCE = Path(
    "docs/evidence/third-party/webcore/WebCore-LICENSE-LGPL-2.txt")
WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256 = "7555fa34bc131a75ca56d65c40cc1ea8f9515d23e353d4c15d58573a042f7805"
WEBCORE_CSS_GENERATED_REVIEW_SOURCE = Path(
    "docs/evidence/v135-runtime-notice-bindings/WEBCORE-CSS-GENERATED-REVIEW-v135.json")
WEBCORE_CSS_GENERATED_REVIEW_SHA256 = "896b02761d0b256d705ff26cf58c39b9d3157e52fb3699435e22be6522e683bc"
WEBCORE_CSS_GENERATED_APPLE_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/WebCore-LICENSE-APPLE.txt")
WEBCORE_CSS_GENERATED_REVIEW_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/CSSGeneratedInputsReview.json")
WEBCORE_CSS_GENERATED_SECTION_MARKER = "## WebCore generated CSS input notices"
WEBCORE_CSS_GENERATED_HTML_MARKER = '<section id="neantik-webcore-css-generated-input-notices">'
WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE = Path(
    "docs/evidence/webkit-v20-webcore-media-controls-rights-boundary-review-20261026.json")
WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256 = "6aefd30127d98c29df1b42c6e56e6ce5bf2e25f4e2380d567220b4e4896b6ef4"
WEBCORE_MEDIA_CONTROLS_REVIEW_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsRightsBoundaryReview.json")
WEBCORE_MEDIA_CONTROLS_OVERLAY_RELATIVE = Path(
    "overlays/neantik-original-media-controls-v2")
WEBCORE_MEDIA_CONTROLS_OVERLAY_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/NeAntik-MediaControls-BSD-2-Clause.txt")
WEBCORE_MEDIA_CONTROLS_OVERLAY_ATTRIBUTION_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsAttribution.json")
WEBCORE_MEDIA_CONTROLS_SECTION_MARKER = "## WebCore modern media controls image resources"
WEBCORE_MEDIA_CONTROLS_HTML_MARKER = '<section id="neantik-webcore-media-controls-images">'
WEBCORE_MODEL_IBL_ROOT = Path("docs/evidence/third-party/neantik-webmodel-ibl")
WEBCORE_MODEL_IBL_LICENSE_SOURCE = WEBCORE_MODEL_IBL_ROOT / "LICENSE.txt"
WEBCORE_MODEL_IBL_ATTRIBUTION_SOURCE = WEBCORE_MODEL_IBL_ROOT / "ATTRIBUTION.json"
WEBCORE_MODEL_IBL_LICENSE_SOURCE = WEBCORE_MODEL_IBL_ROOT / "LICENSE.txt"
WEBCORE_MODEL_IBL_LICENSE_SHA256 = "3ab0de831861966f2c2ec76d3ba1b24473c64ee08cb7699327a2005fca688ff7"
WEBCORE_MODEL_IBL_ATTRIBUTION_SOURCE = WEBCORE_MODEL_IBL_ROOT / "ATTRIBUTION.json"
WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256 = "76648e94a8529fb300d66c34021227a4630383b3a93e960930bcfa1906afe3a0"
WEBCORE_MODEL_IBL_LICENSE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-BSD-2-Clause.txt")
WEBCORE_MODEL_IBL_ATTRIBUTION_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-Attribution.json")
WEBCORE_MODEL_IBL_DIFFUSE_PATH = Path(
    "WebCore.framework/Versions/A/Resources/modelDefaultDiffuseData")
WEBCORE_MODEL_IBL_SPECULAR_PATH = Path(
    "WebCore.framework/Versions/A/Resources/modelDefaultSpecularData")
WEBCORE_MODEL_IBL_DIFFUSE_ORIGINAL_SHA256 = "29a81b4539dccf31a32618e7b7164a61677ed73abb16a1fbbe17c4c314c9632a"
WEBCORE_MODEL_IBL_SPECULAR_ORIGINAL_SHA256 = "64fee6af9089b94448cbb0049763f6f8e7f62cd95042e8d44a6ee6514210458a"
WEBCORE_MODEL_IBL_DIFFUSE_SHA256 = "1c9a94310bb745294484702475c419b4a2fe0027aa71218a7fb1c8c01d7d658d"
WEBCORE_MODEL_IBL_SPECULAR_SHA256 = "4c53b4b6579f33cebb3fc42631e4447e0be9823d949dd2beae4f868c20438cf2"
WEBCORE_MODEL_IBL_SECTION_MARKER = "## WebCore first-party WebModel environment resources"
WEBCORE_MODEL_IBL_HTML_MARKER = '<section id="neantik-webcore-model-ibl-notice">'
IRCAM_LISTEN_HRTF_NOTICE_SOURCE = Path(
    "docs/evidence/third-party/ircam/IRCAM-LISTEN-HRTF-NOTICE.txt")
IRCAM_LISTEN_HRTF_NOTICE_SHA256 = "98e596a4a8e0cd4d5fcb5d77f8a37d846129dce89d99235dcc3133a22dfdd0a2"
IRCAM_LISTEN_HRTF_RUNTIME_PATH = Path(
    "WebCore.framework/Versions/A/Resources/audio/Composite.wav")
IRCAM_LISTEN_HRTF_RUNTIME_SHA256 = (
    "a25fc99a6e875f659aaa9d107c791aeff250030e0d7f16458baf3a00943394e3")
IRCAM_LISTEN_HRTF_NOTICE_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/IRCAM-LISTEN-HRTF-NOTICE.txt")
IRCAM_LISTEN_HRTF_SECTION_MARKER = "## IRCAM LISTEN HRTF dataset permission and attribution"
IRCAM_LISTEN_HRTF_HTML_MARKER = '<section id="neantik-ircam-listen-hrtf-notice">'
WEBRTC_GENERATED_HEADERS_SOURCE = Path(
    "docs/evidence/third-party/webkit-v20-libwebrtc-generated-input-headers.txt")
WEBRTC_GENERATED_HEADERS_SHA256 = "c21fcb2fb91fe612f85385407fc2289846ee4aa2155b9bd179f6868a6c29665b"
WEBRTC_GENERATED_HEADERS_DESTINATION = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebRTC/GeneratedInputHeaders.txt")
WEBRTC_GENERATED_HEADERS_SECTION_MARKER = "## libwebrtc generated-input source headers"
WEBRTC_GENERATED_HEADERS_HTML_MARKER = '<section id="neantik-webrtc-generated-input-headers">'
WEBRTC_SECTION_MARKER = "## Source-derived WebRTC notices: CMake libwebrtc.dylib"
WEBRTC_HTML_MARKER = '<section id="neantik-webrtc-cmake-runtime-notices">'
NOTICE_DESTINATION = Path("Contents/Resources/NeAntikRuntimeNotices.md")
HTML_DESTINATION = Path("Contents/Resources/NeAntikRuntimeCompliance/THIRD-PARTY-NOTICES.html")
SECTION_MARKER = "## Owned WebKit runtime component: CompatibilitySpan"
HTML_MARKER = '<section id="neantik-owned-webkit-compatibility-span">'
LGPL2_SECTION_MARKER = "## WebKit source-referenced license text: LGPL-2"
LGPL2_HTML_MARKER = '<section id="neantik-webcore-lgpl-2-license-text">'
LGPL21_SECTION_MARKER = "## WebKit source-referenced license text: LGPL-2.1"
LGPL21_HTML_MARKER = '<section id="neantik-webcore-lgpl-2-1-license-text">'
ANGLE_SECTION_MARKER = "## Source-mapped WebKit runtime notices: ANGLE"
ANGLE_HTML_MARKER = '<section id="neantik-angle-runtime-notices">'
WEBINSPECTOR_SECTION_MARKER = "## Bundled WebInspectorUI external license resources"
WEBINSPECTOR_HTML_MARKER = '<section id="neantik-webinspector-external-licenses">'
WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE = Path(
    "docs/evidence/third-party/webinspector/WebInspectorUI-framework.LICENSE")
WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256 = "c1493fcceabb2c162ca8a603fd4505c51a24024d8f9aa35ae75aa72df412fc00"
WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses")
    / "WebInspectorUI-framework-BSD-2-Clause.txt")
WEBINSPECTOR_FRAMEWORK_SECTION_MARKER = (
    "## WebInspectorUI framework source-file notice: WebInspectorUI.cpp")
WEBINSPECTOR_FRAMEWORK_HTML_MARKER = (
    '<section id="neantik-webinspector-framework-source-notice">')
WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE = Path(
    "docs/evidence/third-party/webkit-process/AuxiliaryProcessMain-BSD-2-Clause.LICENSE")
WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256 = "193fa78ff7879bf105a6a1ad66a50ba0355d5068e67ed911e4bcee7eb19dc9af"
WEBKIT_XPC_ENTRYPOINT_MAP = Path(
    "docs/evidence/v135-runtime-notice-bindings/WEBKIT-XPC-ENTRYPOINT-MAP-v135.json")
WEBKIT_XPC_ENTRYPOINT_MAP_SHA256 = "74b11548a75a17840fbfff59109c479de60b7da9bbe0d8f54a14fefffa7eb3b3"
WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses")
    / "AuxiliaryProcessMain-BSD-2-Clause.txt")
WEBKIT_XPC_ENTRYPOINT_SECTION_MARKER = (
    "## WebKit XPC process entrypoint source notice: AuxiliaryProcessMain.cpp")
WEBKIT_XPC_ENTRYPOINT_HTML_MARKER = (
    '<section id="neantik-webkit-xpc-entrypoint-source-notice">')
SANDBOX_SOURCE_ROOT = Path("docs/evidence/third-party/webkit-sandbox-source-v20")
SANDBOX_MANIFEST_SHA256 = "b59bd44c1f91dc8d7c17bb3afed8004e43c30ffeb37cfe627fc81bddf278d61d"
SANDBOX_NOTICE_ROOT = Path("Contents/Resources/NeAntikRuntimeLicenses/WebKitSandbox")
SANDBOX_SECTION_MARKER = "## Bundled WebKit sandbox source notices"
SANDBOX_HTML_MARKER = '<section id="neantik-webkit-sandbox-source-notices">'
SOURCE_CROSSWALK = Path("docs/evidence/webkit-v20-source-license-crosswalk-20261024.json")
SOURCE_CROSSWALK_SHA256 = "a4855fed2d0f33b31c791440538dbc481b0176665268e9dd57dbdbc9c23d9191"
V377_TEXT_EXTRACTION_PATCH_SHA256 = "a3a8e43188e6f0fcd3a603e0f3e6a814283da6f56a268f206b10f7fc97416ee2"
V381_CORE_PREDICTION_PATCH_SHA256 = "e2aea7ebc6fba39295e4f4cbdbef157afcae34db252c98d76ae60ffab2cb8d83"
V382_FILTERED_MODEL_SCOPE_PATCH_SHA256 = "5889129ffef355e29e4db9ca5d5ca47f2865e030523c6f4de9fdc5ef869cfdf6"
SOURCE_CORPUS_ROOT = Path("docs/evidence/third-party/webkit-v20-license-text-corpus")
SOURCE_CORPUS_MANIFEST_SHA256 = "959dcc0612f01f3e420837bb917c77cdaa6b06f9d94a6cc6804362bbb9e6fb71"
SOURCE_CANDIDATE_COUNT = 12
SOURCE_CANDIDATE_NOTICE_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebKitSourceCandidates")
SOURCE_CANDIDATE_SECTION_MARKER = "## Pinned WebKit source license-text candidates"
SOURCE_CANDIDATE_HTML_MARKER = '<section id="neantik-webkit-source-license-candidates">'
WEBKIT_SWIFT_SOURCE_NOTICE_ROOT = Path(
    "docs/evidence/third-party/webkit-swift-source-notices")
WEBKIT_SWIFT_MANIFEST_SOURCE = Path(
    "docs/evidence/v135-runtime-notice-bindings/WEBKIT-SWIFT-SOURCE-NOTICES-MANIFEST-v135.json")
WEBKIT_SWIFT_MANIFEST_SHA256 = "86beb8321aa67d5af9ac5d499d1ba0aa0528c15a29900ece3f17791c6b8f38ec"
WEBKIT_SWIFT_NOTICE_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebKitSwift")
WEBKIT_SWIFT_SECTION_MARKER = "## WebKitSwift source-header notices"
WEBKIT_SWIFT_HTML_MARKER = '<section id="neantik-webkit-swift-source-header-notices">'
WEBGPU_IMAGE_PATH = Path("WebGPU.framework/Versions/A/WebGPU")
WEBGPU_IMAGE_SHA256 = "d1c3b7c455a39dd6decac116b87616bd8e392407cb45b542a45b69c109577c84"
# V135 is an immutable historical build receipt. Its output identity remains
# fixed while current package validation follows the independently receipted
# V423 WebGPU relink above.
V135_WEBGPU_IMAGE_SHA256 = "42e1a8d4205948576032c04a428788cd737d06512aac044cc04acb1608b0dc23"
V382_SOURCE_OFFER_MANIFEST_SHA256S = frozenset({
    # Frozen V382 offer and its current V409 V382/V399 recipient-route successor.
    "e96b51e74894ec9877462105cf03c28bc80c0bc799b5408288d7c0b49c4631a8",
    "a81640f1e15c4addf804a0e36aed343cc8e67bf91c504f1e78e32108cfb58291",
    # V423 WebGPU-only relink: all source/build receipt components remain bound;
    # this manifest adds the exact relink review and output component.
    "8445130f3c855a61a4ad5c65e1e70da5c03435e51e0c6d722c518a4597f061a6",
    # V424 adds the exact target-only V423 build receipt as a source-offer component.
    "6c00f25694f25026b882eb02c372b3c30dc87af3aec68409346a22bf02c9db56",
})
V423_WEBGPU_RELINK_RECEIPT = Path(
    "evidence/neantik-v423-webgpu-target-only-relink-20261028.json")
V423_WEBGPU_RELINK_RECEIPT_SHA256 = "4b73031e706c2d8beedfc0c902470ae15d76b6af0055076576464a88fcafecd7"
V424_WEBGPU_RELINK_MANIFEST_SHA256 = "6c00f25694f25026b882eb02c372b3c30dc87af3aec68409346a22bf02c9db56"
V417_PREPARED_BUNDLE_RECEIPT = Path(
    "evidence/neantik-v417-source-rebound-prepared-bundle-20261028.json")
V417_PREPARED_BUNDLE_RECEIPT_SHA256 = (
    "c1acbd34efea02fb3f04b789c58a708d0fc865a9f5526a3d182f5a6918e3fa9d")
V472_PORTABLE_V417_SHA256 = "14a9413063b633ca6df8d9be8c793801be335712add960cb04fd7143fac53917"
V473_PORTABLE_V417_SHA256 = "d09aa4bf105c311745d292ce8c64301d2ccbab9e68e611d55b13b8afade3f29c"
V472_PORTABLE_V420_SHA256 = "c474876aeb8f1f6b38213cd71c25a1e8f82920bc3425979d75c0b06cbc37cdbf"
V414_RUNTIME_IMAGE_BINDING = Path("evidence/neantik-v414-runtime-image-binding.json")
V414_RUNTIME_IMAGE_BINDING_SHA256 = (
    "dc87d6639dfda0ae5561456c4abf46f0dda149f699b82bb2985f537ab6450842")
V414_CANDIDATE_INVENTORY_SHA256 = (
    "5af632a0b0fce9e04e8e9875301f906d3d4027e6b683bde344957fa5b8e42a12")
V420_CURRENT_IMAGE_BINDING_RECEIPT = Path(
    "evidence/neantik-v420-current-four-image-source-notice-bind-20261028.json")
V420_CURRENT_IMAGE_BINDING_RECEIPT_SHA256 = (
    "4af630d3134b5da7140593096cdfc7669635ab00cd0a9fb753713b8cc3761715")
V420_CURRENT_IMAGE_BUILD_OUTPUTS = {
    "JavaScriptCore.framework/Versions/A/JavaScriptCore":
        "fcfce29db5959a47d549b26c6e8539cc5b24ad63abec114189d3053fb9074238",
    "WebCore.framework/Versions/A/WebCore":
        "eaba91766570f71bf3bc4af0ce7e226e7e7415aa8bd5c90649c530349acfef12",
    "WebKit.framework/Versions/A/WebKit":
        "13b735470dc5e3689d101ca3a207f08c5bed00d7e796d59b3217d78c17fcbeda",
    "libwebrtc.dylib":
        "309d95abf602e59d25bf3dc38abe719edc10829ff79cb6a917027edad43e965f",
}
V382_REQUIRED_OUTPUTS = frozenset({
    "JavaScriptCore.framework/Versions/A/JavaScriptCore",
    "WebCore.framework/Versions/A/WebCore",
    "WebGPU.framework/Versions/A/WebGPU",
    "WebInspectorUI.framework/Versions/A/WebInspectorUI",
    "WebKit.framework/Versions/A/WebKit",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.GPU.xpc/Contents/MacOS/app.neantik.desktop.webkit.GPU.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.Networking.xpc/Contents/MacOS/app.neantik.desktop.webkit.Networking.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.CaptivePortal.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.CaptivePortal.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.EnhancedSecurity.Development",
    "WebKit.framework/Versions/A/XPCServices/app.neantik.desktop.webkit.WebContent.xpc/Contents/MacOS/app.neantik.desktop.webkit.WebContent.Development",
    "WebKitLegacy.framework/Versions/A/WebKitLegacy",
    "libANGLE-shared.dylib",
    "libWebKitSwift.dylib",
    "libwebrtc.dylib",
})
_CURRENT_SOURCE_OFFER_DIGEST: ContextVar[str | None] = ContextVar(
    "neantik_current_source_offer_digest", default=None)
_CURRENT_V382_RUNTIME_HASHES: ContextVar[dict[str, str] | None] = ContextVar(
    "neantik_current_v382_runtime_hashes", default=None)
_CURRENT_V420_SIGNED_IMAGE_HASHES: ContextVar[dict[str, str] | None] = ContextVar(
    "neantik_current_v420_signed_image_hashes", default=None)
_CURRENT_PRIVATE_V446_QA: ContextVar[bool] = ContextVar("neantik_private_v446_qa", default=False)


class RuntimeHashBindings(dict[str, str]):
    """Build output hashes and the candidate-signed identities they were signed from."""

    def __init__(self, *args, signed_image_hashes: dict[str, str] | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        self.signed_image_hashes = signed_image_hashes or {}
V135_RUNTIME_BINDING_SUMMARY = Path(
    "docs/evidence/v135-runtime-notice-bindings/V135-RUNTIME-OUTPUT-BINDINGS.json")
V135_RUNTIME_BINDING_SUMMARY_SHA256 = "b200740d32f5456cde00737bd1ecaa9ea82b22cfcfa0eb42d2f58125341479d4"
V135_BUILD_RECEIPT = Path(
    "docs/evidence/neantik-v135-clean-relocated-v132-webkit-relink-20261026.json")
V135_BUILD_RECEIPT_SHA256 = "a491a638ee081d08e330a7a100fb4c738361b066be5bcdb7226b1bc19132ecb4"
WEBGPU_LICENSE_SOURCE = (
    Path("docs/evidence/third-party/webkit-v20-license-text-corpus")
    / "Source/WebCore/LICENSE-APPLE"
)
WEBGPU_LICENSE_NAME = "WebKit-WebGPU-BSD-2-Clause.txt"
WEBGPU_LICENSE_SHA256 = "0b5d3a7cc325942567373b0ecd757d07c132e0ebd7c97bfc63f7e1a76094edb4"
WEBGPU_LICENSE_DESTINATION = (
    Path("Contents/Resources/NeAntikRuntimeLicenses") / WEBGPU_LICENSE_NAME
)
WEBGPU_ADAPTER_HEADER_SOURCE = Path("docs/evidence/third-party/webkit-webgpu-adapter-header.txt")
WEBGPU_ADAPTER_HEADER_SHA256 = "32aa93aeca2c517d10fca33eba8c31741c1568c1f870c6dbbaf918501f741d52"
WEBGPU_ADAPTER_HEADER_DESTINATION = Path("Contents/Resources/NeAntikRuntimeLicenses/WebGPU-Adapter-Source-Header.txt")
WEBGPU_SECTION_MARKER = "## WebGPU runtime image source notice: WebGPU.framework"
WEBGPU_HTML_MARKER = '<section id="neantik-webgpu-runtime-image-notice">'
# Source texts were matched byte-for-byte to these four framework resources in
# the pinned private v16 runtime. This is an inventory, not a terms decision.
WEBINSPECTOR_LICENSES = (
    ("CSSDocumentation", "b5179f780ec212a434efcc989a2295a140deb0bdb17182d2bf9c5f6f1f1a01c4", 1074),
    ("CodeMirror", "168a4becc968f5001e2ee2e0291b6e4daabafc1894a11ade1e11d56e96096e07", 1113),
    ("Esprima", "94bcb9959136723aa4fb36e1a6c4d5c662a2369978cfae344dabfb83ae619e79", 1303),
    ("three.js", "551f06ddc3dc36b56610aa23db680826ba9d9a02e8f89f7bec05d7fa27401a2b", 1081),
)
OWNED_MARKDOWN_MARKERS = (
    SECTION_MARKER, LGPL2_SECTION_MARKER, LGPL21_SECTION_MARKER,
    JSC_COPYING_LIB_SECTION_MARKER,
    JSC_BINJA_SECTION_MARKER,
    JSC_TRI_LICENSE_SECTION_MARKER,
    JSC_HEADERLESS_BSD2_SECTION_MARKER,
    JSC_GENERATED_OUTPUT_SECTION_MARKER,
    JSC_UNICODE_SECTION_MARKER,
    ANGLE_SECTION_MARKER, WEBRTC_SECTION_MARKER, WEBINSPECTOR_SECTION_MARKER,
    LINKED_HEADERS_SECTION_MARKER,
    WEBCORE_GENERATED_HEADERS_SECTION_MARKER,
    WEBCORE_POPOVER_SECTION_MARKER,
    WEBCORE_COLORDATA_SECTION_MARKER,
    WEBCORE_CSS_GENERATED_SECTION_MARKER,
    WEBCORE_MEDIA_CONTROLS_SECTION_MARKER,
    WEBCORE_MODEL_IBL_SECTION_MARKER,
    IRCAM_LISTEN_HRTF_SECTION_MARKER,
    IRCAM_LISTEN_HRTF_SECTION_MARKER,
    "## WebCore first-party replacement resource notices",
    "## WebKit first-party warning color resources",
    WEBRTC_GENERATED_HEADERS_SECTION_MARKER,
    WEBINSPECTOR_FRAMEWORK_SECTION_MARKER,
    WEBKIT_XPC_ENTRYPOINT_SECTION_MARKER,
    SANDBOX_SECTION_MARKER, SOURCE_CANDIDATE_SECTION_MARKER,
    WEBKIT_SWIFT_SECTION_MARKER, WEBGPU_SECTION_MARKER,
)
OWNED_HTML_MARKERS = (
    HTML_MARKER, LGPL2_HTML_MARKER, LGPL21_HTML_MARKER,
    JSC_COPYING_LIB_HTML_MARKER,
    JSC_BINJA_HTML_MARKER,
    JSC_TRI_LICENSE_HTML_MARKER,
    JSC_HEADERLESS_BSD2_HTML_MARKER,
    JSC_GENERATED_OUTPUT_HTML_MARKER,
    JSC_UNICODE_HTML_MARKER,
    ANGLE_HTML_MARKER, WEBRTC_HTML_MARKER, WEBINSPECTOR_HTML_MARKER,
    LINKED_HEADERS_HTML_MARKER,
    WEBCORE_GENERATED_HEADERS_HTML_MARKER,
    WEBCORE_POPOVER_HTML_MARKER,
    WEBCORE_COLORDATA_HTML_MARKER,
    WEBCORE_CSS_GENERATED_HTML_MARKER,
    WEBCORE_MEDIA_CONTROLS_HTML_MARKER,
    WEBCORE_MODEL_IBL_HTML_MARKER,
    IRCAM_LISTEN_HRTF_HTML_MARKER,
    IRCAM_LISTEN_HRTF_HTML_MARKER,
    '<section id="neantik-webcore-first-party-replacement-notices">',
    '<section id="neantik-webkit-warning-colors-notices">',
    WEBRTC_GENERATED_HEADERS_HTML_MARKER,
    WEBINSPECTOR_FRAMEWORK_HTML_MARKER,
    WEBKIT_XPC_ENTRYPOINT_HTML_MARKER,
    SANDBOX_HTML_MARKER, SOURCE_CANDIDATE_HTML_MARKER,
    WEBKIT_SWIFT_HTML_MARKER, WEBGPU_HTML_MARKER,
)
MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
RUNTIME_IMAGE_BINDING_FILE = "NeAntikRuntimeImageBinding.json"


class NoticeError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_v135_runtime_binding_evidence(project_root: Path) -> dict:
    """Require the separate V135 output table to match its exact clean-build receipt."""
    summary_path = _physical_path_beneath(
        project_root, V135_RUNTIME_BINDING_SUMMARY,
        label="V135 runtime output binding summary")
    receipt_path = _physical_path_beneath(
        project_root, V135_BUILD_RECEIPT, label="exact V135 WebKit build receipt")
    if (sha256_file(summary_path) != V135_RUNTIME_BINDING_SUMMARY_SHA256
            or sha256_file(receipt_path) != V135_BUILD_RECEIPT_SHA256):
        raise NoticeError("V135 runtime binding summary or build receipt SHA-256 mismatch")
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("V135 runtime binding evidence is invalid JSON") from error
    binding = summary.get("binding", {})
    expected_binding = {
        "buildReceiptPath": V135_BUILD_RECEIPT.as_posix(),
        "buildReceiptSHA256": V135_BUILD_RECEIPT_SHA256,
        "webkitCommit": "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c",
        "sourceArchiveSHA256": "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f",
        "mainSourcePatchSHA256": "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735",
        "v36PatchSHA256": "0ade0fcd5dd315677d182a86c3d37ea7582dc63457e5c6870df2040f7f182b06",
        "scope": "Exact runtime output identity only; historical source/license reviews remain bounded and unchanged in meaning.",
    }
    receipt_rows = receipt.get("outputs", [])
    summary_rows = summary.get("outputs", [])
    expected_rows = [{key: row.get(key) for key in ("path", "sha256", "architecture", "bytes")}
                     for row in receipt_rows if isinstance(row, dict)]
    if (summary.get("schemaVersion") != 1
            or summary.get("status") != "PASS_V135_BUILD_OUTPUT_IDENTITY_REBIND; SOURCE_TERMS_REVIEWS_RETAINED_AT_BOUNDED_SCOPE"
            or binding != expected_binding
            or receipt.get("id") != "neantik-v135-clean-relocated-v132-webkit-relink-20261026"
            or receipt.get("inputs", {}).get("sourceArchiveSHA256") != expected_binding["sourceArchiveSHA256"]
            or receipt.get("inputs", {}).get("mainSourcePatchSHA256") != expected_binding["mainSourcePatchSHA256"]
            or receipt.get("inputs", {}).get("v36PatchSHA256") != expected_binding["v36PatchSHA256"]
            or len(receipt_rows) != 14 or summary_rows != expected_rows
            or any(row.get("architecture") != "arm64" for row in summary_rows)):
        raise NoticeError("V135 runtime output table does not match its exact build receipt")
    hashes = {row["path"]: row["sha256"] for row in summary_rows}
    expected_images = {
        "JavaScriptCore.framework/Versions/A/JavaScriptCore": V135_JSC_HEADERLESS_BSD2_IMAGE_SHA256,
        "WebGPU.framework/Versions/A/WebGPU": V135_WEBGPU_IMAGE_SHA256,
        "WebCore.framework/Versions/A/WebCore": WEBCORE_POPOVER_RUNTIME_SHA256,
        "WebKit.framework/Versions/A/WebKit": "9d22770904538771607524af37bba48f45959d3aadc41b96ba8bf40f02018ab6",
        "libwebrtc.dylib": "dbed8455ea0c93bdd7c20c5ce79723a545a23d12dd22e9da92277d13a4b6efae",
        "libWebKitSwift.dylib": "a30fe4e2947b08ea17c784218a2c833426be9040f52d136f29a9abd070044b41",
    }
    if any(hashes.get(path) != digest for path, digest in expected_images.items()):
        raise NoticeError("V135 runtime output identities differ from pinned notice bindings")
    evidence_dir = project_root / "docs/evidence/v135-runtime-notice-bindings"
    expected_review_hashes = {
        "JSC-HEADERLESS-INPUTS-REVIEW-v135.json": V135_JSC_HEADERLESS_BSD2_REVIEW_SHA256,
        "JSC-GENERATED-OUTPUT-MANIFEST-v135.json": V135_JSC_GENERATED_OUTPUT_MANIFEST_SHA256,
        "LINKED-SOURCE-HEADERS-MANIFEST-v135.json": LINKED_HEADERS_MANIFEST_SHA256,
        "WEBCORE-POPOVER-REVIEW-v135.json": WEBCORE_POPOVER_REVIEW_SHA256,
        "WEBCORE-COLORDATA-REVIEW-v135.json": WEBCORE_COLORDATA_REVIEW_SHA256,
        "WEBCORE-CSS-GENERATED-REVIEW-v135.json": WEBCORE_CSS_GENERATED_REVIEW_SHA256,
        "WEBGPU-IMAGE-REVIEW-v135.json": "1f47b0fe5132ba283c9e87dd7c21ec98c83d52d3d5361f5ba84dc7459830501f",
        "WEBKIT-SWIFT-SOURCE-NOTICES-MANIFEST-v135.json": WEBKIT_SWIFT_MANIFEST_SHA256,
        "WEBKIT-XPC-ENTRYPOINT-MAP-v135.json": WEBKIT_XPC_ENTRYPOINT_MAP_SHA256,
    }
    evidence: dict[str, dict] = {}
    for name, expected_digest in expected_review_hashes.items():
        path = _physical_path_beneath(project_root, V135_RUNTIME_BINDING_SUMMARY.parent / name,
                                      label=f"V135 source-review binding {name}")
        if sha256_file(path) != expected_digest:
            raise NoticeError(f"V135 source-review evidence hash mismatch: {name}")
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise NoticeError(f"V135 source-review binding is invalid: {name}") from error
        item_binding = data.get("v135Binding")
        if (not isinstance(item_binding, dict)
                or item_binding.get("buildReceiptSHA256") != V135_BUILD_RECEIPT_SHA256
                or item_binding.get("sourceArchiveSHA256") != expected_binding["sourceArchiveSHA256"]
                or item_binding.get("mainSourcePatchSHA256") != expected_binding["mainSourcePatchSHA256"]
                or item_binding.get("v36PatchSHA256") != expected_binding["v36PatchSHA256"]):
            raise NoticeError(f"V135 source-review binding does not match build receipt: {name}")
        evidence[name] = data
    if (evidence["JSC-HEADERLESS-INPUTS-REVIEW-v135.json"].get("sourceBinding", {}).get("runtimeImageSHA256")
            != hashes["JavaScriptCore.framework/Versions/A/JavaScriptCore"]
            or evidence["JSC-GENERATED-OUTPUT-MANIFEST-v135.json"].get("runtimeImage", {}).get("sha256")
            != hashes["JavaScriptCore.framework/Versions/A/JavaScriptCore"]
            or evidence["WEBCORE-POPOVER-REVIEW-v135.json"].get("sourceBinding", {}).get("runtimeImageSHA256")
            != hashes["WebCore.framework/Versions/A/WebCore"]
            or evidence["WEBCORE-COLORDATA-REVIEW-v135.json"].get("sourceBinding", {}).get("runtimeImageSHA256")
            != hashes["WebCore.framework/Versions/A/WebCore"]
            or evidence["WEBCORE-CSS-GENERATED-REVIEW-v135.json"].get("sourceBinding", {}).get("runtimeImageSHA256")
            != hashes["WebCore.framework/Versions/A/WebCore"]
            or evidence["WEBGPU-IMAGE-REVIEW-v135.json"].get("runtimeImage", {}).get("sha256")
            != hashes["WebGPU.framework/Versions/A/WebGPU"]
            or any(row.get("runtimeSHA256") != hashes.get(row.get("runtimePath"))
                   for row in evidence["LINKED-SOURCE-HEADERS-MANIFEST-v135.json"].get("images", []))
            or any(row.get("sha256") != hashes.get(row.get("path"), hashes.get("libWebKitSwift.dylib"))
                   for row in evidence["WEBKIT-SWIFT-SOURCE-NOTICES-MANIFEST-v135.json"].get("runtimeImages", []))
            or any(row.get("runtimeSHA256") != hashes.get(row.get("runtimePath"))
                   for row in evidence["WEBKIT-XPC-ENTRYPOINT-MAP-v135.json"].get("runtimeImages", []))):
        raise NoticeError("V135 source notice rows do not match exact build output identities")
    return summary


V465_RUNTIME_BINDING_PATH = Path("evidence/V445-BASELINE-RUNTIME-IDENTITY.json")
V465_RUNTIME_BINDING_SHA256 = "dfd1ec9f71d5d59da2c405f9c45579bf2a374b250e5ce1f5cad2399610d9182e"
V465_LOCAL_BINDING_PATH = Path("docs/evidence/v465-runtime-bindings/V445-BASELINE-RUNTIME-IDENTITY.json")
V467_RUNTIME_BINDING_PATH = Path("evidence/V466-STABILIZED-RUNTIME-IDENTITY.json")
V467_RUNTIME_BINDING_SHA256 = "ace2e90d03cb752df509f1177bbcaaac0e9403826be9dd757ad1749a201c071e"
V467_LOCAL_BINDING_PATH = Path("docs/evidence/v467-runtime-bindings/V466-STABILIZED-RUNTIME-IDENTITY.json")


def _v465_runtime_binding(project_root: Path, offer_root: Path, manifest: dict,
                          historic_signed_paths: set[str], *, stabilized: bool = False) -> RuntimeHashBindings:
    """Bind an exact frozen baseline; this is not legal approval."""
    field = "currentWebKitV467StabilizedRuntime" if stabilized else "currentWebKitV465BaselineRuntime"
    relative = V467_RUNTIME_BINDING_PATH if stabilized else V465_RUNTIME_BINDING_PATH
    local_relative = V467_LOCAL_BINDING_PATH if stabilized else V465_LOCAL_BINDING_PATH
    expected_sha = V467_RUNTIME_BINDING_SHA256 if stabilized else V465_RUNTIME_BINDING_SHA256
    expected_id = "V467-stabilized-baseline-runtime-binding" if stabilized else "V465-clean-baseline-runtime-binding"
    binding = manifest[field]
    path = _physical_path_beneath(offer_root, relative,
                                  label="V465 baseline runtime identity")
    local = _physical_path_beneath(project_root, local_relative,
                                   label="V465 local runtime identity")
    rows = [row for row in manifest["sourceOfferComponents"]
            if row.get("path") == relative.as_posix()]
    if (not isinstance(binding, dict)
            or binding.get("path") != relative.as_posix()
            or binding.get("sha256") != expected_sha
            or len(rows) != 1 or rows[0].get("includedInOfferFolder") is not True
            or rows[0].get("bytes") != path.stat().st_size
            or rows[0].get("sha256") != expected_sha
            or sha256_file(path) != expected_sha
            or sha256_file(local) != expected_sha):
        raise ValueError("V465 exact identity component mismatch")
    data = json.loads(path.read_text(encoding="utf-8"))
    outputs, images, assets = data["buildOutputs"], data["stageAndSignedImages"], data["compiledAssets"]
    if (data.get("schemaVersion") != 1 or data.get("id") != expected_id
            or data.get("sourceArchiveSHA256") != "35e88c74041d81d75e54aa6f914c94029b5a0c74ceac5a9162cf009460b790cd"
            or not isinstance(outputs, list) or len(outputs) != 14
            or {r.get("path") for r in outputs} != V382_REQUIRED_OUTPUTS
            or not isinstance(images, list) or len(images) != 16
            or {r.get("path") for r in images} != historic_signed_paths
            or assets.get("path") != "WebKit.framework/Versions/A/Resources/Assets.car"
            or assets.get("sha256") != "4554bf51ecaed1db9021776be273b73cbebd3b97809f50bfc80b20f735559ed4"):
        raise ValueError("V465 runtime identity scope mismatch")
    staged = {}; signed = {}
    for row in images:
        key = row["path"]
        if any(not isinstance(row.get(field), str) or re.fullmatch(r"[0-9a-f]{64}", row[field]) is None
               for field in ("buildStageSHA256", "signedSHA256")):
            raise ValueError("V465 image digest malformed")
        staged[key] = row["buildStageSHA256"]; signed[key] = row["signedSHA256"]
    values = dict(staged)
    for row in outputs:
        key = row["path"]; stage_key = key if key in staged else "WebKit.framework/Versions/A/Frameworks/" + key
        if (row.get("architecture") != "arm64" or type(row.get("bytes")) is not int
                or row["bytes"] <= 0 or staged.get(stage_key) != row.get("sha256")):
            raise ValueError("V465 build to staged image mismatch")
        values[key] = row["sha256"]
        values[stage_key] = row["sha256"]
    values[assets["path"]] = assets["sha256"]
    return RuntimeHashBindings(values, signed_image_hashes=signed)


def _v382_runtime_hashes(project_root: Path, source_offer_root: Path | None,
                         expected_manifest_sha256: str | None = None) -> dict[str, str] | None:
    """Load runtime identities only from the exact source-offer-bound V382 receipt."""
    if source_offer_root is None:
        if expected_manifest_sha256 is not None:
            raise NoticeError("source-offer root required for explicit manifest identity")
        return None
    if source_offer_root.is_symlink() or not source_offer_root.is_dir():
        raise NoticeError("pinned WebKit source offer is not a physical directory")
    offer_root = source_offer_root.resolve(strict=True)
    manifest_path = _physical_path_beneath(offer_root, Path("manifest.json"),
                                           label="V382 source-offer manifest")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest_digest = sha256_file(manifest_path)
        if expected_manifest_sha256 is not None:
            if (not isinstance(expected_manifest_sha256, str)
                    or re.fullmatch(r"[0-9a-f]{64}", expected_manifest_sha256) is None
                    or manifest_digest != expected_manifest_sha256):
                raise ValueError("explicit source-offer manifest SHA-256 mismatch")
        if manifest.get("currentWebKitV382FilteredModelSource") is None:
            if expected_manifest_sha256 is not None:
                raise ValueError("explicit offer lacks V382 binding")
            return None
        if (manifest_digest not in V382_SOURCE_OFFER_MANIFEST_SHA256S
                and expected_manifest_sha256 is None):
            raise ValueError("V382 source-offer manifest SHA-256 mismatch")
        if (manifest_digest not in V382_SOURCE_OFFER_MANIFEST_SHA256S
                and manifest.get("currentWebGPUV423TargetRelink") is None):
            raise ValueError("explicit new offer lacks V423 binding")
        binding = manifest["currentWebKitV382FilteredModelSource"]
        receipt_relative = Path(binding["buildReceiptPath"])
        if receipt_relative.is_absolute() or ".." in receipt_relative.parts:
            raise ValueError("unsafe V382 build receipt path")
        receipt_path = _physical_path_beneath(offer_root, receipt_relative,
                                              label="V382 filtered WebKit build receipt")
        component = next(row for row in manifest["sourceOfferComponents"]
                        if row.get("path") == receipt_relative.as_posix())
        receipt_digest = binding["buildReceiptSHA256"]
        if (component.get("includedInOfferFolder") is not True
                or component.get("bytes") != receipt_path.stat().st_size
                or component.get("sha256") != receipt_digest
                or sha256_file(receipt_path) != receipt_digest):
            raise ValueError("V382 build receipt is not bound as an exact offer component")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        outputs = receipt["outputs"]
        if (receipt.get("schemaVersion") != 1
                or receipt.get("id") != "neantik-v382-filtered-model-webkit-build"
                or not str(receipt.get("status", "")).startswith(
                    "PASS_FILTERED_MODEL_WEBKIT_BUILD_14_OF_14_ARM64")
                or receipt.get("checks", {}).get("allArm64") is not True
                or receipt.get("checks", {}).get("ninjaDryRunNoWork") is not True
                or not isinstance(outputs, list) or len(outputs) != 14
                or {row.get("path") for row in outputs if isinstance(row, dict)}
                    != V382_REQUIRED_OUTPUTS):
            raise ValueError("V382 build receipt does not describe the exact runtime outputs")
        result: dict[str, str] = {}
        signed_image_hashes: dict[str, str] = {}
        for row in outputs:
            path, digest = row.get("path"), row.get("sha256")
            if (row.get("architecture") != "arm64"
                    or type(row.get("bytes")) is not int or row["bytes"] <= 0
                    or not isinstance(digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
                raise ValueError("malformed V382 runtime output row")
            result[path] = digest
        asset_receipt_relative = Path(binding["assetCatalogReceiptPath"])
        if asset_receipt_relative.is_absolute() or ".." in asset_receipt_relative.parts:
            raise ValueError("unsafe V382 asset catalog receipt path")
        asset_receipt_path = _physical_path_beneath(
            offer_root, asset_receipt_relative, label="V382 WebKit asset catalog receipt")
        asset_component = next(row for row in manifest["sourceOfferComponents"]
                               if row.get("path") == asset_receipt_relative.as_posix())
        asset_receipt_digest = binding["assetCatalogReceiptSHA256"]
        if (asset_component.get("includedInOfferFolder") is not True
                or asset_component.get("bytes") != asset_receipt_path.stat().st_size
                or asset_component.get("sha256") != asset_receipt_digest
                or sha256_file(asset_receipt_path) != asset_receipt_digest):
            raise ValueError("V382 asset catalog receipt is not bound as an exact offer component")
        asset_receipt = json.loads(asset_receipt_path.read_text(encoding="utf-8"))
        asset_output = asset_receipt["output"]
        overlay = offer_root / "overlays/neantik-first-party-warning-colors-v1"
        attribution_path = _physical_path_beneath(
            overlay, Path("ATTRIBUTION.json"), label="V382 warning-color source attribution")
        attribution_sha = sha256_file(attribution_path)
        if (asset_receipt.get("schemaVersion") != 1
                or asset_receipt.get("id") != "neantik-v394-webkit-warning-color-assets-car-build"
                or asset_receipt.get("status") != "PASS_V382_WEBKIT_ASSETS_CATALOG_BUILD_ONE_ACTION"
                or asset_receipt.get("sourceOverlay", {}).get("assetCount") != 9
                or asset_receipt.get("sourceOverlay", {}).get("attributionSHA256") != attribution_sha
                or asset_receipt.get("build", {}).get("target") != "WebKit_Assets"
                or asset_receipt.get("build", {}).get("requestedActions") != 1
                or asset_output.get("path") != "WebKit.framework/Versions/A/Resources/Assets.car"
                or type(asset_output.get("bytes")) is not int or asset_output["bytes"] < 1
                or not re.fullmatch(r"[0-9a-f]{64}", asset_output.get("sha256", ""))):
            raise ValueError("V382 warning-color asset catalog receipt fields mismatch")
        result[asset_output["path"]] = asset_output["sha256"]
        nested_swift = "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib"
        result[nested_swift] = result["libWebKitSwift.dylib"]
        if (manifest_digest == V424_WEBGPU_RELINK_MANIFEST_SHA256
                or (expected_manifest_sha256 is not None
                    and manifest.get("currentWebGPUV423TargetRelink") is not None)):
            prepared_binding = manifest.get("currentWebKitV417PreparedBundle")
            prepared_relative = Path(prepared_binding["evidence"])
            prepared_path = _physical_path_beneath(
                offer_root, prepared_relative, label="V417 prepared bundle receipt")
            prepared_component = next(
                row for row in manifest["sourceOfferComponents"]
                if row.get("path") == prepared_relative.as_posix())
            prepared_digest = prepared_binding.get("sha256")
            if (prepared_relative != V417_PREPARED_BUNDLE_RECEIPT
                    or prepared_digest not in {V417_PREPARED_BUNDLE_RECEIPT_SHA256, V472_PORTABLE_V417_SHA256, V473_PORTABLE_V417_SHA256}
                    or prepared_component.get("includedInOfferFolder") is not True
                    or prepared_component.get("bytes") != prepared_path.stat().st_size
                    or prepared_component.get("sha256") != prepared_digest
                    or sha256_file(prepared_path) != prepared_digest):
                raise ValueError("V417 prepared bundle receipt is not an exact source-offer component")
            prepared = json.loads(prepared_path.read_text(encoding="utf-8"))
            if prepared_digest in {V472_PORTABLE_V417_SHA256, V473_PORTABLE_V417_SHA256} and (
                    prepared.get("priorCurrent", {}).get("path") != "[local checkpoint path redacted]"
                    or prepared.get("portableRedaction", {}).get("originalReceiptSHA256") != V417_PREPARED_BUNDLE_RECEIPT_SHA256
                    or prepared.get("portableRedaction", {}).get("redactedFields") != (
                        ["priorCurrent.path", "candidate.root", "candidate.appPath"]
                        if prepared_digest == V473_PORTABLE_V417_SHA256 else ["priorCurrent.path"])):
                raise ValueError("V417 portable redaction provenance mismatch")
            prepared_candidate = prepared.get("candidate", {})
            candidate_root = prepared_candidate.get("root")
            expected_candidate_inventory = V414_CANDIDATE_INVENTORY_SHA256
            if (prepared.get("id") != "V417"
                    or prepared.get("source", {}).get("commit") !=
                        "2fac0fb9b8c25578fe5a6874ae32b0b06678ee0b"
                    or prepared.get("source", {}).get("worktreeState") != "clean"
                    or not isinstance(candidate_root, str)
                    or Path(candidate_root).name != "25aea06ab1f84885a5e35f2a75623322"
                    or prepared_candidate.get("inventorySHA256") != expected_candidate_inventory
                    or prepared_candidate.get("matchesV414AppInventory") is not True):
                raise ValueError("V417 exact candidate inventory binding mismatch")

            candidate_binding = manifest.get("currentWebKitV414RuntimeImageBinding")
            candidate_binding_relative = Path(candidate_binding["evidence"])
            candidate_binding_path = _physical_path_beneath(
                offer_root, candidate_binding_relative,
                label="V414 candidate runtime image binding")
            candidate_binding_component = next(
                row for row in manifest["sourceOfferComponents"]
                if row.get("path") == candidate_binding_relative.as_posix())
            if (candidate_binding_relative != V414_RUNTIME_IMAGE_BINDING
                    or candidate_binding.get("sha256") != V414_RUNTIME_IMAGE_BINDING_SHA256
                    or candidate_binding.get("candidateId") !=
                        "25aea06ab1f84885a5e35f2a75623322"
                    or candidate_binding.get("candidateInventorySHA256") != expected_candidate_inventory
                    or candidate_binding_component.get("includedInOfferFolder") is not True
                    or candidate_binding_component.get("bytes") != candidate_binding_path.stat().st_size
                    or candidate_binding_component.get("sha256") != V414_RUNTIME_IMAGE_BINDING_SHA256
                    or sha256_file(candidate_binding_path) != V414_RUNTIME_IMAGE_BINDING_SHA256):
                raise ValueError("V414 candidate image binding is not an exact source-offer component")
            candidate_binding_data = json.loads(candidate_binding_path.read_text(encoding="utf-8"))
            candidate_rows = candidate_binding_data.get("images", [])
            if (candidate_binding_data.get("schemaVersion") != 1
                    or candidate_binding_data.get("status") != "recipient-signed-runtime-image-binding"
                    or candidate_binding_data.get("imageCount") != 16
                    or len(candidate_rows) != 16):
                raise ValueError("V414 candidate runtime image binding schema mismatch")
            candidate_paths: set[str] = set()
            candidate_signed_hashes: dict[str, str] = {}
            for row in candidate_rows:
                path = row.get("path")
                if (not isinstance(path, str) or path in candidate_paths
                        or Path(path).is_absolute() or ".." in Path(path).parts
                        or any(not isinstance(row.get(key), str)
                               or re.fullmatch(r"[0-9a-f]{64}", row[key]) is None
                               for key in ("sourceInputSHA256", "recipientSignedSHA256"))):
                    raise ValueError("V414 candidate runtime image row is malformed")
                candidate_paths.add(path)
                candidate_signed_hashes[path] = row["recipientSignedSHA256"]
                result_key = path
                if path in {
                    "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib",
                    "WebKit.framework/Versions/A/Frameworks/libANGLE-shared.dylib",
                }:
                    result_key = Path(path).name
                if path == WEBGPU_IMAGE_PATH.as_posix() or path == "libswiftCompatibilitySpan.dylib":
                    continue
                if result_key not in result or row["sourceInputSHA256"] != result[result_key]:
                    raise ValueError(f"V414 candidate build input mismatch: {path}")
            signed_image_hashes = candidate_signed_hashes

            binding = manifest.get("currentWebKitV420FourImageNoticeBinding")
            binding_relative = Path(binding["evidence"])
            binding_path = _physical_path_beneath(
                offer_root, binding_relative, label="V420 current image binding receipt")
            binding_component = next(
                row for row in manifest["sourceOfferComponents"]
                if row.get("path") == binding_relative.as_posix())
            binding_digest = binding.get("sha256")
            if (binding_relative != V420_CURRENT_IMAGE_BINDING_RECEIPT
                    or binding_digest not in {V420_CURRENT_IMAGE_BINDING_RECEIPT_SHA256, V472_PORTABLE_V420_SHA256}
                    or binding_component.get("includedInOfferFolder") is not True
                    or binding_component.get("sha256") != binding_digest
                    or binding_component.get("bytes") != binding_path.stat().st_size
                    or sha256_file(binding_path) != binding_digest):
                raise ValueError("V420 current image binding is not an exact source-offer component")
            current_binding = json.loads(binding_path.read_text(encoding="utf-8"))
            if binding_digest == V472_PORTABLE_V420_SHA256 and (
                    current_binding.get("priorCurrent", {}).get("path") != "[local checkpoint path redacted]"
                    or current_binding.get("portableRedaction", {}).get("originalReceiptSHA256") != V420_CURRENT_IMAGE_BINDING_RECEIPT_SHA256
                    or current_binding.get("portableRedaction", {}).get("redactedFields") != ["priorCurrent.path"]):
                raise ValueError("V420 portable redaction provenance mismatch")
            expected_candidate = {
                "candidateId": "25aea06ab1f84885a5e35f2a75623322",
                "version": "1.0.0",
                "build": "201",
                "bundleInventorySHA256": "5af632a0b0fce9e04e8e9875301f906d3d4027e6b683bde344957fa5b8e42a12",
            }
            image_rows = current_binding.get("images", [])
            image_outputs = {row.get("path"): row.get("currentBuildOutputSHA256")
                             for row in image_rows if isinstance(row, dict)}
            v420_signed_image_hashes = {
                row["path"]: row["currentSignedSHA256"]
                for row in image_rows if isinstance(row, dict)
                and isinstance(row.get("path"), str)
                and isinstance(row.get("currentSignedSHA256"), str)
            }
            if (current_binding.get("id") != "V420"
                    or current_binding.get("candidate") != expected_candidate
                    or current_binding.get("source", {}).get("webkitCommit") !=
                        "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
                    or current_binding.get("source", {}).get("buildReceiptSHA256") !=
                        "319afbac5c8a7b55daeb54912b3c7614537a4d26315885127d54694dc3bc7a7f"
                    or len(image_rows) != 4
                    or image_outputs != V420_CURRENT_IMAGE_BUILD_OUTPUTS
                    or any(row.get("stagedBuildOutputMatches") is not True
                           or row.get("rawOutputHashInCandidateNotice") is not True
                           for row in image_rows)):
                raise ValueError("V420 exact current source/build image bindings mismatch")
            if any(signed_image_hashes.get(path) != digest
                   for path, digest in v420_signed_image_hashes.items()):
                raise ValueError("V420 signed image identities differ from the exact V414 candidate")
            if any(signed_image_hashes.get(path) != row.get("currentSignedSHA256")
                   for row in image_rows for path in [row.get("path")]):
                raise ValueError("V420 signed image identities differ from the exact V414 candidate")
            result.update(V420_CURRENT_IMAGE_BUILD_OUTPUTS)
            relink = manifest.get("currentWebGPUV423TargetRelink")
            receipt_relative = Path(relink["receiptPath"])
            component = next(row for row in manifest["sourceOfferComponents"]
                             if row.get("path") == receipt_relative.as_posix())
            relink_path = _physical_path_beneath(
                offer_root, receipt_relative, label="V423 WebGPU target relink receipt")
            if (receipt_relative != V423_WEBGPU_RELINK_RECEIPT
                    or relink.get("receiptSHA256") != V423_WEBGPU_RELINK_RECEIPT_SHA256
                    or relink.get("outputPath") != WEBGPU_IMAGE_PATH.as_posix()
                    or relink.get("outputSHA256") != WEBGPU_IMAGE_SHA256
                    or component.get("includedInOfferFolder") is not True
                    or component.get("bytes") != relink_path.stat().st_size
                    or component.get("sha256") != V423_WEBGPU_RELINK_RECEIPT_SHA256
                    or sha256_file(relink_path) != V423_WEBGPU_RELINK_RECEIPT_SHA256):
                raise ValueError("V423 WebGPU relink receipt is not bound as an exact offer component")
            relink_receipt = json.loads(relink_path.read_text(encoding="utf-8"))
            relink_inputs = relink_receipt.get("inputs", {})
            relink_output = relink_receipt.get("output", {})
            # This is the immutable V423 receipt's historical field, not the
            # observed file length. Production admission separately requires
            # the hash-bound V434 correction before staging this output.
            if (relink_receipt.get("id") != "V423"
                    or relink_receipt.get("classification") !=
                        "TARGET_ONLY_WEBGPU_LINK_SUCCEEDED_IN_COPY_ON_WRITE_BUILD_TREE; CANDIDATE_NOT_MUTATED; RELEASE_NOT_QUALIFIED"
                    or relink_inputs.get("V382BuildReceipt", {}).get("sha256") != receipt_digest
                    or relink_inputs.get("V382BuildReceipt", {}).get("expectedWebGPUOutputSHA256")
                        != result[WEBGPU_IMAGE_PATH.as_posix()]
                    or relink_inputs.get("sourceOfferManifestSHA256") !=
                        "a81640f1e15c4addf804a0e36aed343cc8e67bf91c504f1e78e32108cfb58291"
                    or relink_inputs.get("sourceCompileInputs") !=
                        "3040/3040 pinned-source-tree compile-input rows byte/hash matched the retained V20 source tree; WebGPU-path rows 6/6 matched."
                    or relink_inputs.get("buildConfiguration", {}).get("CMakeCacheSHA256") !=
                        "bf38a4db6cf695dbc6b88d878c379521a97b87d7ea93c1ef493c0f9b929ea17c"
                    or relink_inputs.get("buildConfiguration", {}).get("buildNinjaSHA256") !=
                        "691f704d4a75b80b5f4e8652a1d758b78e135f83b089b61a378df3c20bffc570"
                    or not isinstance(relink_output.get("path"), str)
                    or not relink_output["path"].endswith(
                        "/" + WEBGPU_IMAGE_PATH.as_posix())
                    or relink_output.get("sha256") != WEBGPU_IMAGE_SHA256
                    or relink_output.get("architecture") != "arm64"
                    or relink_output.get("bytes") != 4_007_776
                    or relink_output.get("developerIDSigned") is not False):
                raise ValueError("V423 WebGPU target relink receipt fields mismatch")
            result[WEBGPU_IMAGE_PATH.as_posix()] = WEBGPU_IMAGE_SHA256
        fresh_fields = ("currentWebKitV465BaselineRuntime", "currentWebKitV467StabilizedRuntime")
        selected = [field for field in fresh_fields if manifest.get(field) is not None]
        if selected:
            if len(selected) != 1 or expected_manifest_sha256 is None or len(signed_image_hashes) != 16:
                raise ValueError("fresh runtime requires one explicit manifest and prior 16-image validation")
            return _v465_runtime_binding(project_root, offer_root, manifest, set(signed_image_hashes),
                                         stabilized=selected[0] == fresh_fields[1])
        return RuntimeHashBindings(result, signed_image_hashes=signed_image_hashes)
    except (KeyError, StopIteration, TypeError, ValueError, OSError,
            UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("V382 filtered build receipt binding is invalid") from error


def _current_runtime_hash(relative: Path | str, fallback: str) -> str:
    hashes = _CURRENT_V382_RUNTIME_HASHES.get()
    return hashes.get(Path(relative).as_posix(), fallback) if hashes else fallback


def _with_v382_runtime_hashes(function):
    @wraps(function)
    def wrapped(app, runtime_frameworks=None, *, project_root=PROJECT_ROOT,
                source_offer_root=None, source_offer_manifest_sha256=None):
        effective_digest = (source_offer_manifest_sha256 if source_offer_manifest_sha256 is not None
                            else _CURRENT_SOURCE_OFFER_DIGEST.get())
        hashes = _v382_runtime_hashes(project_root, source_offer_root, effective_digest)
        if _CURRENT_PRIVATE_V446_QA.get():
            if effective_digest != "988f05c617ac7ddf460c37ac5de3537f2fb7b5bc60cf0dbfa634aed951f63faf" or not isinstance(hashes, RuntimeHashBindings):
                raise NoticeError("private V446 QA requires the exact V465 offer")
            hashes = RuntimeHashBindings(hashes, signed_image_hashes=dict(hashes.signed_image_hashes))
            hashes[WEBGPU_IMAGE_PATH.as_posix()] = "fd292af52b1011541c6bed02c010cdada4c51d2f115ffc0ce334dd679ae4daac"
        digest_token = _CURRENT_SOURCE_OFFER_DIGEST.set(effective_digest)
        token = _CURRENT_V382_RUNTIME_HASHES.set(hashes)
        signed_token = _CURRENT_V420_SIGNED_IMAGE_HASHES.set(
            getattr(hashes, "signed_image_hashes", {}))
        try:
            return function(app, runtime_frameworks, project_root=project_root,
                            source_offer_root=source_offer_root)
        finally:
            _CURRENT_V420_SIGNED_IMAGE_HASHES.reset(signed_token)
            _CURRENT_V382_RUNTIME_HASHES.reset(token)
            _CURRENT_SOURCE_OFFER_DIGEST.reset(digest_token)
    return wrapped


def _runtime_image_build_sha(runtime_frameworks: Path, relative: Path,
                             expected_source_sha256: str | None) -> str:
    """Return the pinned pre-sign build hash for an exact signed runtime image.

    Recipient signing and RPATH relocation change Mach-O bytes. The re-sign
    producer records the input, relocated and final signed hashes in a map
    embedded in the signed host. Unbound pre-sign staging trees still require
    the exact pinned file hash.
    """
    image = _physical_path_beneath(
        runtime_frameworks, relative, label=f"pinned runtime image {relative.as_posix()}")
    actual_sha256 = sha256_file(image)
    expected_source_sha256 = _current_runtime_hash(relative, expected_source_sha256)
    if expected_source_sha256 is not None and actual_sha256 == expected_source_sha256:
        return actual_sha256

    binding_candidates = [
        runtime_frameworks / RUNTIME_IMAGE_BINDING_FILE,
        runtime_frameworks.parent / f"{runtime_frameworks.name}.{RUNTIME_IMAGE_BINDING_FILE}",
        runtime_frameworks.parent / "Resources/NeAntikRuntimeEvidence" / RUNTIME_IMAGE_BINDING_FILE,
    ]
    binding_path = next((candidate for candidate in binding_candidates
                         if candidate.is_file() and not candidate.is_symlink()), None)
    if binding_path is None:
        binding_path = binding_candidates[0]
    if binding_path.is_symlink():
        raise NoticeError("recipient runtime image binding must be a regular file")
    if not binding_path.is_file():
        if expected_source_sha256 is None:
            return actual_sha256
        raise NoticeError(f"runtime image SHA-256 mismatch: {relative.as_posix()}")
    if binding_path.stat().st_size > 2_000_000:
        raise NoticeError("recipient runtime image binding exceeds the size limit")
    try:
        binding = json.loads(binding_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("recipient runtime image binding is invalid JSON") from error
    rows = binding.get("images") if isinstance(binding, dict) else None
    if (not isinstance(binding, dict) or binding.get("schemaVersion") != 1
            or binding.get("status") != "recipient-signed-runtime-image-binding"
            or not isinstance(rows, list) or not 1 <= len(rows) <= 128
            or binding.get("imageCount") != len(rows)):
        raise NoticeError("recipient runtime image binding has an unexpected schema")
    seen: set[str] = set()
    selected = None
    for row in rows:
        if not isinstance(row, dict):
            raise NoticeError("recipient runtime image binding row is malformed")
        path = row.get("path")
        source_hash = row.get("sourceInputSHA256")
        relocated_hash = row.get("relocatedSHA256")
        signed_hash = row.get("recipientSignedSHA256")
        if (not isinstance(path, str) or "\\" in path or Path(path).is_absolute()
                or ".." in Path(path).parts
                or path in seen or any(not isinstance(value, str)
                                       or re.fullmatch(r"[0-9a-f]{64}", value) is None
                                       for value in (source_hash, relocated_hash, signed_hash))):
            raise NoticeError("recipient runtime image binding row is malformed")
        seen.add(path)
        if path == relative.as_posix():
            selected = row
    candidate_signed_sha256 = (_CURRENT_V420_SIGNED_IMAGE_HASHES.get() or {}).get(
        relative.as_posix())
    if (selected is None
            or (expected_source_sha256 is not None
                and selected["sourceInputSHA256"] not in
                    {expected_source_sha256, candidate_signed_sha256})
            or selected["recipientSignedSHA256"] != actual_sha256):
        raise NoticeError(f"runtime image SHA-256 mismatch: {relative.as_posix()}")
    if candidate_signed_sha256 is not None and selected["sourceInputSHA256"] == candidate_signed_sha256:
        return expected_source_sha256 or selected["sourceInputSHA256"]
    return selected["sourceInputSHA256"]


def _runtime_relative_path(runtime_frameworks: Path, image: Path) -> Path:
    try:
        return image.resolve(strict=True).relative_to(runtime_frameworks.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise NoticeError("runtime image escapes the owned Frameworks tree") from error


def _physical_file(path: Path, *, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise NoticeError(f"{label} must be a regular non-symlinked file")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise NoticeError(f"{label} must be a regular file")


def _safe_destination(app: Path, relative: Path, *, create_parent: bool) -> Path:
    if app.is_symlink() or not app.is_dir():
        raise NoticeError("app bundle must be an existing physical directory")
    root = app.resolve(strict=True)
    destination = app / relative
    current = app
    for part in relative.parts[:-1]:
        current = current / part
        if current.exists() or current.is_symlink():
            if current.is_symlink() or not current.is_dir():
                raise NoticeError(f"unsafe non-directory path in app bundle: {relative}")
        elif create_parent:
            current.mkdir()
        else:
            raise NoticeError(f"required app resource directory is missing: {relative.parent}")
        try:
            current.resolve(strict=True).relative_to(root)
        except (OSError, ValueError) as error:
            raise NoticeError(f"app resource path escapes bundle: {relative}") from error
    if destination.is_symlink():
        raise NoticeError(f"app resource must not be a symlink: {relative}")
    if destination.exists() and not destination.is_file():
        raise NoticeError(f"app resource must be a regular file: {relative}")
    return destination


def _compatibility_span(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = []
    for candidate in runtime_frameworks.rglob("libswiftCompatibilitySpan.dylib"):
        if candidate.is_symlink():
            raise NoticeError("CompatibilitySpan runtime image must not be a symlink")
        if candidate.is_file():
            candidates.append(candidate)
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libswiftCompatibilitySpan.dylib")
    library = candidates[0]
    _physical_file(library, label="CompatibilitySpan runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("CompatibilitySpan runtime image is not a Mach-O file")
    return library


def _angle_library(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = list(runtime_frameworks.rglob("libANGLE-shared.dylib"))
    if any(candidate.is_symlink() for candidate in candidates):
        raise NoticeError("ANGLE runtime image must not be a symlink")
    candidates = [candidate for candidate in candidates if candidate.is_file()]
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libANGLE-shared.dylib")
    library = candidates[0]
    _physical_file(library, label="ANGLE runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("ANGLE runtime image is not a Mach-O file")
    return library


def _webrtc_library(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    candidates = list(runtime_frameworks.rglob(WEBRTC_IMAGE_NAME))
    if any(candidate.is_symlink() for candidate in candidates):
        raise NoticeError("WebRTC runtime image must not be a symlink")
    candidates = [candidate for candidate in candidates if candidate.is_file()]
    if len(candidates) != 1:
        raise NoticeError("expected exactly one bundled libwebrtc.dylib")
    library = candidates[0]
    _physical_file(library, label="WebRTC runtime image")
    with library.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("WebRTC runtime image is not a Mach-O file")
    return library


def _safe_manifest_relative(value: object, *, field: str) -> Path:
    if not isinstance(value, str) or "\\" in value:
        raise NoticeError(f"WebRTC manifest {field} is not a safe relative path")
    posix = PurePosixPath(value)
    if posix.is_absolute() or not posix.parts or any(part in ("", ".", "..") for part in posix.parts):
        raise NoticeError(f"WebRTC manifest {field} is not a safe relative path")
    return Path(*posix.parts)


def _physical_path_beneath(root: Path, relative: Path, *, label: str) -> Path:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise NoticeError(f"{label} must not traverse a symlink")
    _physical_file(current, label=label)
    try:
        current.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise NoticeError(f"{label} escapes its pinned root") from error
    return current


def _remove_owned_markdown_sections(text: str) -> str:
    """Remove only prior generated WebKit H2 sections; refuse duplicate markers."""
    lines = text.splitlines(keepends=True)
    result: list[str] = []
    index = 0
    while index < len(lines):
        heading = lines[index].rstrip("\r\n")
        if heading not in OWNED_MARKDOWN_MARKERS:
            result.append(lines[index])
            index += 1
            continue
        if sum(line.rstrip("\r\n") == heading for line in lines) != 1:
            raise NoticeError(f"duplicate owned-WebKit Markdown marker: {heading}")
        index += 1
        while index < len(lines) and not lines[index].startswith("## "):
            index += 1
    return "".join(result).rstrip() + "\n"


def _remove_owned_html_sections(text: str) -> str:
    """Remove prior generated HTML sections by unique section ID."""
    for marker in OWNED_HTML_MARKERS:
        count = text.count(marker)
        if count > 1:
            raise NoticeError(f"duplicate owned-WebKit HTML marker: {marker}")
        if count == 1:
            start = text.index(marker)
            end = text.find("</section>", start + len(marker))
            if end < 0:
                raise NoticeError(f"unterminated owned-WebKit HTML section: {marker}")
            end += len("</section>")
            if text[end:end + 1] == "\n":
                end += 1
            text = text[:start] + text[end:]
    return text


def _webrtc_notice_sources(project_root: Path) -> tuple[dict, tuple[tuple[Path, Path, str, int], ...]]:
    manifest_path = project_root / WEBRTC_MANIFEST_SOURCE
    _physical_file(manifest_path, label="pinned WebRTC candidate manifest")
    manifest_bytes = manifest_path.read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != WEBRTC_MANIFEST_SHA256:
        raise NoticeError("pinned WebRTC candidate manifest SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, ValueError) as error:
        raise NoticeError("pinned WebRTC candidate manifest is invalid JSON") from error
    if (manifest.get("schemaVersion") != 1
            or manifest.get("upstream", {}).get("sha256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or manifest.get("status") != "research supplement; generated index covers all 2505 source-join paths with exact license-file references and explicit generated-input exceptions; applicability and release gates remain open"
            or manifest.get("noticeFileCount") != 63):
        raise NoticeError("pinned WebRTC candidate manifest scope or provenance mismatch")
    notices = manifest.get("notices")
    if not isinstance(notices, list) or len(notices) != 63:
        raise NoticeError("pinned WebRTC notice count mismatch")
    candidate_root = project_root / WEBRTC_CANDIDATE_ROOT
    if candidate_root.is_symlink() or not candidate_root.is_dir():
        raise NoticeError("pinned WebRTC candidate root must be a physical directory")
    result = []
    seen_sources: set[Path] = set()
    seen_outputs: set[Path] = set()
    generated_index = manifest.get("generatedThirdPartyIndex")
    if (not isinstance(generated_index, dict)
            or generated_index.get("path") != "files/Source/ThirdParty/libwebrtc/Source/webrtc/LICENSE_THIRD_PARTY"
            or generated_index.get("generatedNotUpstream") is not True):
        raise NoticeError("pinned WebRTC generated third-party index metadata mismatch")
    index_entry_found = False
    for entry in notices:
        if not isinstance(entry, dict):
            raise NoticeError("pinned WebRTC notice entry is invalid")
        manifest_path = _safe_manifest_relative(entry.get("path"), field="path")
        if manifest_path == Path("NeAntik-usage_exit_stub-MPL-2.0.txt"):
            if (entry.get("sha256") != WEBRTC_MPL2_SHA256
                    or entry.get("bytes") != 16726):
                raise NoticeError("pinned WebRTC shim MPL-2.0 manifest entry mismatch")
            continue  # Installed separately at WEBRTC_MPL2_DESTINATION.
        if not manifest_path.parts or manifest_path.parts[0] != "files":
            raise NoticeError("pinned WebRTC notice path is outside files/")
        source_relative = Path(*manifest_path.parts[1:])
        output_relative = manifest_path
        if (manifest_path.as_posix() == generated_index["path"]
                and entry.get("sha256") == generated_index.get("sha256")
                and entry.get("bytes") == generated_index.get("bytes")):
            index_entry_found = True
        if source_relative in seen_sources or output_relative in seen_outputs:
            raise NoticeError("pinned WebRTC manifest contains duplicate paths")
        seen_sources.add(source_relative)
        seen_outputs.add(output_relative)
        digest = entry.get("sha256")
        size = entry.get("bytes")
        if (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or type(size) is not int or size < 0):
            raise NoticeError("pinned WebRTC notice hash or byte count is invalid")
        source = _physical_path_beneath(
            candidate_root, output_relative, label=f"pinned WebRTC notice {source_relative}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebRTC notice source hash/size mismatch: {source_relative}")
        result.append((source_relative, output_relative, digest, size))
    if len(result) != 62 or not index_entry_found:
        raise NoticeError("pinned WebRTC notice files or generated index are incomplete")
    return manifest, tuple(result)


def _webrtc_mpl2_license(project_root: Path) -> Path:
    source = project_root / WEBRTC_MPL2_SOURCE
    _physical_file(source, label="official MPL-2.0 text for NeAntik WebRTC shim")
    if sha256_file(source) != WEBRTC_MPL2_SHA256:
        raise NoticeError("pinned WebRTC shim MPL-2.0 license SHA-256 mismatch")
    return source


def _webrtc_libwebm_authors(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, WEBRTC_LIBWEBM_AUTHORS_SOURCE,
                                    label="pinned libwebm authors supplement")
    if source.stat().st_size != 137 or sha256_file(source) != WEBRTC_LIBWEBM_AUTHORS_SHA256:
        raise NoticeError("pinned libwebm authors supplement hash/size mismatch")
    return source


def _verify_packaged_libwebm_authors(app: Path, source: Path) -> None:
    packaged = _safe_destination(app, WEBRTC_LIBWEBM_AUTHORS_DESTINATION, create_parent=False)
    _physical_file(packaged, label="packaged libwebm authors supplement")
    if (packaged.stat().st_size != 137 or sha256_file(packaged) != WEBRTC_LIBWEBM_AUTHORS_SHA256
            or packaged.read_bytes() != source.read_bytes()):
        raise NoticeError("packaged libwebm authors supplement differs from pinned source")


def _dav1d_headers(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, DAV1D_HEADERS_SOURCE,
                                    label="pinned dav1d source headers")
    if source.stat().st_size != 15342 or sha256_file(source) != DAV1D_HEADERS_SHA256:
        raise NoticeError("pinned dav1d source headers hash/size mismatch")
    return source


def _rnnoise_header(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, RNNOISE_HEADER_SOURCE,
                                    label="pinned rnnoise source header")
    if source.stat().st_size != 1461 or sha256_file(source) != RNNOISE_HEADER_SHA256:
        raise NoticeError("pinned rnnoise source header hash/size mismatch")
    return source


def _libsrtp_headers(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, LIBSRTP_HEADERS_SOURCE,
                                    label="pinned libsrtp source headers")
    if source.stat().st_size != 15682 or sha256_file(source) != LIBSRTP_HEADERS_SHA256:
        raise NoticeError("pinned libsrtp source headers hash/size mismatch")
    return source


def _opus_headers(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, OPUS_HEADERS_SOURCE,
                                    label="pinned Opus source headers")
    if source.stat().st_size != 6106 or sha256_file(source) != OPUS_HEADERS_SHA256:
        raise NoticeError("pinned Opus source headers hash/size mismatch")
    return source


def _verify_packaged_opus_headers(app: Path, source: Path) -> None:
    packaged = _safe_destination(app, OPUS_HEADERS_DESTINATION, create_parent=False)
    _physical_file(packaged, label="packaged Opus source headers")
    if (packaged.stat().st_size != 6106 or sha256_file(packaged) != OPUS_HEADERS_SHA256
            or packaged.read_bytes() != source.read_bytes()):
        raise NoticeError("packaged Opus source headers differ from pinned source")


def _verify_packaged_libsrtp_headers(app: Path, source: Path) -> None:
    packaged = _safe_destination(app, LIBSRTP_HEADERS_DESTINATION, create_parent=False)
    _physical_file(packaged, label="packaged libsrtp source headers")
    if (packaged.stat().st_size != 15682 or sha256_file(packaged) != LIBSRTP_HEADERS_SHA256
            or packaged.read_bytes() != source.read_bytes()):
        raise NoticeError("packaged libsrtp source headers differ from pinned source")


def _verify_packaged_rnnoise_header(app: Path, source: Path) -> None:
    packaged = _safe_destination(app, RNNOISE_HEADER_DESTINATION, create_parent=False)
    _physical_file(packaged, label="packaged rnnoise source header")
    if (packaged.stat().st_size != 1461 or sha256_file(packaged) != RNNOISE_HEADER_SHA256
            or packaged.read_bytes() != source.read_bytes()):
        raise NoticeError("packaged rnnoise source header differs from pinned source")


def _verify_packaged_dav1d_headers(app: Path, source: Path) -> None:
    packaged = _safe_destination(app, DAV1D_HEADERS_DESTINATION, create_parent=False)
    _physical_file(packaged, label="packaged dav1d source headers")
    if (packaged.stat().st_size != 15342 or sha256_file(packaged) != DAV1D_HEADERS_SHA256
            or packaged.read_bytes() != source.read_bytes()):
        raise NoticeError("packaged dav1d source headers differ from pinned source")


def _linked_source_header_notices(project_root: Path) -> tuple[dict, tuple[tuple[Path, str, int], ...]]:
    """Load three immutable source-header bundles for exact v20 link inputs."""
    manifest_path = _physical_path_beneath(
        project_root, LINKED_HEADERS_MANIFEST_SOURCE,
        label="pinned linked source-header manifest")
    if sha256_file(manifest_path) != LINKED_HEADERS_MANIFEST_SHA256:
        raise NoticeError("pinned linked source-header manifest SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("pinned linked source-header manifest is invalid") from error
    images = manifest.get("images")
    expected = {
        "JavaScriptCore.framework/Versions/A/JavaScriptCore": (906, "JavaScriptCore-SOURCE-HEADERS.txt"),
        "WebCore.framework/Versions/A/WebCore": (2028, "WebCore-SOURCE-HEADERS.txt"),
        "WebKit.framework/Versions/A/WebKit": (193, "WebKit-SOURCE-HEADERS.txt"),
    }
    if (manifest.get("schemaVersion") != 1
            or manifest.get("status") != "exact linked source header notice candidate; generated/conditional and complete image terms remain under review"
            or not isinstance(images, list) or len(images) != 3
            or {row.get("runtimePath") for row in images if isinstance(row, dict)} != set(expected)):
        raise NoticeError("pinned linked source-header manifest scope mismatch")
    notices = []
    for row in images:
        count, name = expected[row["runtimePath"]]
        digest = row.get("noticeSHA256")
        size = row.get("noticeBytes")
        if (row.get("noticePath") != name or row.get("noticeEntryCount") != count
                or len(row.get("entries", [])) != count
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or type(size) is not int or size <= 0):
            raise NoticeError("pinned linked source-header manifest row mismatch")
        source = _physical_path_beneath(
            project_root, LINKED_HEADERS_SOURCE_ROOT / name,
            label=f"pinned linked source-header notice {name}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned linked source-header notice hash/size mismatch: {name}")
        notices.append((source, digest, size))
    return manifest, tuple(notices)


def _license(project_root: Path) -> Path:
    source = project_root / LICENSE_SOURCE
    _physical_file(source, label="canonical Swift runtime license")
    if sha256_file(source) != LICENSE_SHA256:
        raise NoticeError("canonical Swift runtime license SHA-256 mismatch")
    return source


def _jsc_copying_lib_license(project_root: Path) -> Path:
    source = _physical_path_beneath(
        project_root, JSC_COPYING_LIB_SOURCE,
        label="pinned JavaScriptCore COPYING.LIB text")
    if sha256_file(source) != JSC_COPYING_LIB_SHA256:
        raise NoticeError("pinned JavaScriptCore COPYING.LIB SHA-256 mismatch")
    return source


def _jsc_binja_license_sources(project_root: Path) -> tuple[Path, Path]:
    attribution = _physical_path_beneath(
        project_root, JSC_BINJA_ATTRIBUTION_SOURCE,
        label="pinned Binary Ninja attribution text")
    apache = _physical_path_beneath(
        project_root, JSC_BINJA_APACHE_SOURCE,
        label="pinned Apache License 2.0 text")
    if sha256_file(attribution) != JSC_BINJA_ATTRIBUTION_SHA256:
        raise NoticeError("pinned Binary Ninja attribution SHA-256 mismatch")
    if sha256_file(apache) != JSC_BINJA_APACHE_SHA256:
        raise NoticeError("pinned Binary Ninja Apache license SHA-256 mismatch")
    return attribution, apache


def _webcore_lgpl2_license(project_root: Path) -> Path:
    source = project_root / WEBCORE_LGPL2_SOURCE
    _physical_file(source, label="pinned WebCore LGPL-2 license text")
    if sha256_file(source) != WEBCORE_LGPL2_SHA256:
        raise NoticeError("pinned WebCore LGPL-2 license SHA-256 mismatch")
    return source


def _webcore_lgpl21_license(project_root: Path) -> Path:
    source = project_root / WEBCORE_LGPL21_SOURCE
    _physical_file(source, label="pinned WebCore LGPL-2.1 license text")
    if sha256_file(source) != WEBCORE_LGPL21_SHA256:
        raise NoticeError("pinned WebCore LGPL-2.1 license SHA-256 mismatch")
    return source


def _webcore_popover_notice_sources(
    project_root: Path, linked_headers_manifest: dict,
) -> tuple[Path, Path]:
    """Validate the row-specific BSD-2 notice and exact upstream attribution."""
    license_path = _physical_path_beneath(
        project_root, WEBCORE_POPOVER_LICENSE_SOURCE,
        label="pinned WebCore popover.css BSD-2 text")
    template_path = _physical_path_beneath(
        project_root, WEBCORE_POPOVER_LICENSE_TEMPLATE_SOURCE,
        label="pinned WebCore Apple BSD-2 template")
    review_path = _physical_path_beneath(
        project_root, WEBCORE_POPOVER_REVIEW_SOURCE,
        label="pinned WebCore popover.css source review")
    if (sha256_file(license_path) != WEBCORE_POPOVER_LICENSE_SHA256
            or sha256_file(template_path) != WEBCORE_POPOVER_LICENSE_TEMPLATE_SHA256):
        raise NoticeError("WebCore popover.css BSD-2 source text hash mismatch")
    template_lines = template_path.read_bytes().splitlines(keepends=True)
    expected_license = (b"Copyright (C) 2023 Tim Nguyen.\n"
                        + b"".join(template_lines[1:]))
    if license_path.read_bytes() != expected_license:
        raise NoticeError("WebCore popover.css BSD-2 text differs from pinned template")
    if sha256_file(review_path) != WEBCORE_POPOVER_REVIEW_SHA256:
        raise NoticeError("WebCore popover.css source-review SHA-256 mismatch")
    try:
        review = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("WebCore popover.css source review is invalid JSON") from error
    binding = review.get("sourceBinding", {})
    attribution = review.get("attribution", {})
    decision = review.get("noticeStatus", {})
    webcore_images = [row for row in linked_headers_manifest.get("images", [])
                      if isinstance(row, dict)
                      and row.get("runtimePath") == "WebCore.framework/Versions/A/WebCore"]
    if (review.get("schemaVersion") != 1
            or review.get("status") != "TERMS_CLASSIFIED_ATTRIBUTION_MAINTAINER_DECISION_RUNTIME_NOTICE_BINDING_OPEN"
            or binding.get("sourcePath") != "Source/WebCore/css/popover.css"
            or binding.get("sourceSHA256") != "0c46fec1026f3c6b9b2fa90724cf12c39b3a8628857a30675f39e4f14f6a62a6"
            or binding.get("runtimeImageSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or len(webcore_images) != 1
            or webcore_images[0].get("runtimeSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or review.get("upstreamIntroduction", {}).get("commit") != "d4485d2afa7b018f2b75f15c2050e3b94971881d"
            or review.get("policy", {}).get("classification") != "Maintainer classifies this exact new WebKit contribution as BSD-2-Clause based on exact pinned source hash, new-file commit, and official policy. This is not a legal opinion."
            or attribution.get("copyrightNotice") != "Copyright (C) 2023 Tim Nguyen."
            or not decision.get("runtimeNoticeBoundToThisFile")
            or decision.get("runtimeLicenseTextSHA256") != WEBCORE_POPOVER_LICENSE_SHA256):
        raise NoticeError("WebCore popover.css review scope/attribution mismatch")
    return license_path, review_path


def _webcore_colordata_notice_sources(
    project_root: Path, linked_headers_manifest: dict,
) -> tuple[Path, Path]:
    """Validate the exact ColorData BSD-2 text, lineage and author attribution."""
    license_path = _physical_path_beneath(
        project_root, WEBCORE_COLORDATA_LICENSE_SOURCE,
        label="pinned WebCore ColorData BSD-2 text")
    template_path = _physical_path_beneath(
        project_root, WEBCORE_POPOVER_LICENSE_TEMPLATE_SOURCE,
        label="pinned WebCore Apple BSD-2 template")
    review_path = _physical_path_beneath(
        project_root, WEBCORE_COLORDATA_REVIEW_SOURCE,
        label="pinned WebCore ColorData source review")
    if (sha256_file(license_path) != WEBCORE_COLORDATA_LICENSE_SHA256
            or sha256_file(template_path) != WEBCORE_POPOVER_LICENSE_TEMPLATE_SHA256):
        raise NoticeError("WebCore ColorData BSD-2 source text hash mismatch")
    template_lines = template_path.read_bytes().splitlines(keepends=True)
    expected_license = b"Copyright (C) 2002 Darin Adler.\n" + b"".join(template_lines[1:])
    if license_path.read_bytes() != expected_license:
        raise NoticeError("WebCore ColorData BSD-2 text differs from pinned template")
    if sha256_file(review_path) != WEBCORE_COLORDATA_REVIEW_SHA256:
        raise NoticeError("WebCore ColorData source-review SHA-256 mismatch")
    try:
        review = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("WebCore ColorData source review is invalid JSON") from error
    binding = review.get("sourceBinding", {})
    origin = review.get("origin", {})
    attribution = review.get("attribution", {})
    webcore_images = [row for row in linked_headers_manifest.get("images", [])
                      if isinstance(row, dict)
                      and row.get("runtimePath") == "WebCore.framework/Versions/A/WebCore"]
    if (review.get("schemaVersion") != 1
            or review.get("status") != "TERMS_AND_AUTHOR_ATTRIBUTION_CLASSIFIED_RUNTIME_NOTICE_BINDING_OPEN"
            or binding.get("sourcePath") != "Source/WebCore/platform/ColorData.gperf"
            or binding.get("sourceSHA256") != "dc1f82bbdc6090f232b5aabd9a86eacb44df1dd23e6f68f4e08e0b378ee8836d"
            or binding.get("runtimeImageSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or len(webcore_images) != 1
            or webcore_images[0].get("runtimeSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or origin.get("firstAddedByCommit") != "5f5a2bc50fe448d0881140493bfd7786025ef8e9"
            or origin.get("rawFileSHA256") != "23d8556e375c045860b4571912ae5a953ea5b3fe5b485d4ef5620aab6f8a761e"
            or origin.get("author") != "Darin Adler"
            or attribution.get("adoptedCopyrightLine") != "Copyright (C) 2002 Darin Adler."
            or review.get("licenseNotice", {}).get("licenseSHA256")
            != WEBCORE_COLORDATA_LICENSE_SHA256):
        raise NoticeError("WebCore ColorData review scope/attribution mismatch")
    return license_path, review_path


def _webcore_css_generated_notice_sources(
    project_root: Path, linked_headers_manifest: dict,
) -> tuple[Path, Path, Path]:
    """Validate project-level Apple/LGPL texts and the exact headerless CSS review."""
    apple_license = _physical_path_beneath(
        project_root, WEBCORE_CSS_GENERATED_APPLE_LICENSE_SOURCE,
        label="pinned WebCore Apple BSD-2 license text")
    lgpl2_license = _physical_path_beneath(
        project_root, WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SOURCE,
        label="pinned WebCore LGPL-2 license text")
    review_path = _physical_path_beneath(
        project_root, WEBCORE_CSS_GENERATED_REVIEW_SOURCE,
        label="pinned WebCore generated CSS source review")
    if sha256_file(apple_license) != WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256:
        raise NoticeError("pinned WebCore Apple BSD-2 license SHA-256 mismatch")
    if sha256_file(lgpl2_license) != WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256:
        raise NoticeError("pinned WebCore LGPL-2 license SHA-256 mismatch")
    if sha256_file(review_path) != WEBCORE_CSS_GENERATED_REVIEW_SHA256:
        raise NoticeError("pinned WebCore generated CSS review SHA-256 mismatch")
    try:
        review = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("WebCore generated CSS review is invalid JSON") from error
    source_binding = review.get("sourceBinding", {})
    apple_image = [row for row in linked_headers_manifest.get("images", [])
                   if isinstance(row, dict)
                   and row.get("runtimePath") == "WebCore.framework/Versions/A/WebCore"]
    expected_inputs = {
        "Source/WebCore/css/CSSProperties.json": "f56793c6ac7a23a32ce70620febbfcee54f0fc8ae0e3c7fb18f42a68ca043343",
        "Source/WebCore/css/CSSValueKeywords.in": "fa5b9337b00c1acadacfd9ce5da60b234ee1a0a74e5be6fcebe93ce266f9621d",
        "Source/WebCore/css/SVGCSSValueKeywords.in": "bf79271aa57cb8f68425b767ea9c3be8ef00bf8f7ef6a29add484d04bdd38ef4",
    }
    rows = review.get("sourceBinding", {}).get("inputs", [])
    actual_inputs = {row.get("path"): row.get("sha256") for row in rows if isinstance(row, dict)}
    if (review.get("schemaVersion") != 1
            or review.get("status") != "TERMS_CLASSIFIED_PROJECT_LEVEL_NOTICE_PRESERVED_PER_FILE_RIGHTSHOLDER_UNRESOLVED"
            or source_binding.get("sourceArchiveSHA256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or source_binding.get("webkitPatchSHA256") != "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
            or source_binding.get("runtimeImagePath") != "WebCore.framework/Versions/A/WebCore"
            or source_binding.get("runtimeImageSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or len(apple_image) != 1
            or apple_image[0].get("runtimeSHA256") != WEBCORE_POPOVER_RUNTIME_SHA256
            or actual_inputs != expected_inputs
            or any(row.get("perFileCopyrightHeaderPresent") is not False
                   or row.get("individualRightsAssignmentProven") is not False
                   for row in rows if isinstance(row, dict))
            or review.get("noticeDecision", {}).get("appleLicenseTextSHA256")
            != WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256
            or review.get("noticeDecision", {}).get("lgpl2LicenseTextSHA256")
            != WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256):
        raise NoticeError("WebCore generated CSS review scope/attribution mismatch")
    return apple_license, lgpl2_license, review_path


def _webcore_media_controls_notice_sources(project_root: Path) -> Path:
    """Validate provenance and retain UNKNOWN rights for 35 exact image assets."""
    review_path = _physical_path_beneath(
        project_root, WEBCORE_MEDIA_CONTROLS_REVIEW_SOURCE,
        label="pinned WebCore media-controls rights-boundary review")
    if sha256_file(review_path) != WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256:
        raise NoticeError("pinned WebCore media-controls rights review SHA-256 mismatch")
    try:
        review = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("WebCore media-controls rights review is invalid JSON") from error
    rows = review.get("assetRows")
    valid_rows = (isinstance(rows, list) and len(rows) == 35
                  and all(isinstance(row, dict)
                          and isinstance(row.get("runtimePath"), str)
                          and row["runtimePath"].startswith(
                              "WebCore.framework/Versions/A/Resources/modern-media-controls/images/")
                          and isinstance(row.get("sourcePath"), str)
                          and row["sourcePath"].startswith(
                              "Source/WebCore/Modules/modern-media-controls/images/macOS/")
                          and row.get("sourceEqualsRuntimeBytes") is True
                          and re.fullmatch(r"[0-9a-f]{64}", row.get("runtimeSHA256", ""))
                          and row.get("runtimeSHA256") == row.get("sourceSHA256")
                          and isinstance(row.get("originCommit"), str)
                          and isinstance(row.get("author"), str)
                          and isinstance(row.get("reviewer"), str)
                          for row in rows))
    if (review.get("schemaVersion") != 1
            or review.get("status") != (
                "EXACT_ORIGIN_HISTORY_CONFIRMED; OFFICIAL_WEBKIT_POLICY_REQUIRES_APPLICABLE_PROJECT_TERMS; "
                "PER_ASSET_TERMS_AND_COPYRIGHT_ATTRIBUTION_NOT_ESTABLISHED; UNKNOWN RETAINED")
            or review.get("bindings", {}).get("worksheetSHA256")
            != "b5d00e7589a67102c62372a6feddc9e7d06a50c6d0c3b6fde047bd42b9954441"
            or review.get("bindings", {}).get("sourceArchiveSHA256")
            != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or review.get("maintainerDisposition", {}).get("applicableLicense") != "UNKNOWN"
            or review.get("maintainerDisposition", {}).get("requiredCopyrightAttribution") != "UNKNOWN"
            or review.get("summary", {}).get("worksheetUnknownsPreserved") != 78
            or not valid_rows
            or len({row["runtimePath"] for row in rows}) != 35
            or len({row["sourcePath"] for row in rows}) != 35):
        raise NoticeError("WebCore media-controls rights-boundary review scope or binding mismatch")
    return review_path


def _webcore_model_ibl_notice_sources(
    project_root: Path, runtime_frameworks: Path | None,
) -> dict[str, object] | None:
    """Bind the first-party BSD notice only to the exact replacement resources."""
    if runtime_frameworks is None:
        return None
    webcore_bundle = runtime_frameworks / "WebCore.framework"
    if not webcore_bundle.exists() and not webcore_bundle.is_symlink():
        return None
    if webcore_bundle.is_symlink() or not webcore_bundle.is_dir():
        raise NoticeError("WebCore framework must be a physical directory for WebModel notice binding")
    diffuse = _physical_path_beneath(
        runtime_frameworks, WEBCORE_MODEL_IBL_DIFFUSE_PATH,
        label="WebCore WebModel diffuse environment resource")
    specular = _physical_path_beneath(
        runtime_frameworks, WEBCORE_MODEL_IBL_SPECULAR_PATH,
        label="WebCore WebModel specular environment resource")
    diffuse_hash = sha256_file(diffuse)
    specular_hash = sha256_file(specular)
    if (diffuse_hash == WEBCORE_MODEL_IBL_DIFFUSE_ORIGINAL_SHA256
            and specular_hash == WEBCORE_MODEL_IBL_SPECULAR_ORIGINAL_SHA256):
        raise NoticeError(
            "WebCore WebModel resources still contain upstream bytes without a cleared notice binding")
    if (diffuse_hash != WEBCORE_MODEL_IBL_DIFFUSE_SHA256
            or specular_hash != WEBCORE_MODEL_IBL_SPECULAR_SHA256):
        raise NoticeError("WebCore WebModel resource hashes do not match the cleared first-party overlay")
    license_source = _physical_path_beneath(
        project_root, WEBCORE_MODEL_IBL_LICENSE_SOURCE,
        label="first-party WebModel BSD-2-Clause license")
    attribution_source = _physical_path_beneath(
        project_root, WEBCORE_MODEL_IBL_ATTRIBUTION_SOURCE,
        label="first-party WebModel resource attribution")
    if (sha256_file(license_source) != WEBCORE_MODEL_IBL_LICENSE_SHA256
            or sha256_file(attribution_source) != WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256):
        raise NoticeError("pinned WebModel first-party license or attribution changed")
    try:
        attribution = json.loads(attribution_source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("WebModel first-party attribution is invalid JSON") from error
    rows = {row.get("path"): row for row in attribution.get("assets", [])
            if isinstance(row, dict)}
    diffuse_row = rows.get("Source/WebCore/Resources/modelDefaultDiffuseData", {})
    specular_row = rows.get("Source/WebCore/Resources/modelDefaultSpecularData", {})
    if (attribution.get("license") != "BSD-2-Clause"
            or attribution.get("assetCount") != 2
            or diffuse_row.get("sha256") != WEBCORE_MODEL_IBL_DIFFUSE_SHA256
            or specular_row.get("sha256") != WEBCORE_MODEL_IBL_SPECULAR_SHA256
            or diffuse_row.get("license") != "BSD-2-Clause"
            or specular_row.get("license") != "BSD-2-Clause"):
        raise NoticeError("WebModel attribution does not bind both runtime resources to BSD-2-Clause")
    return {
        "license": license_source,
        "attribution": attribution_source,
        "diffuseSHA256": diffuse_hash,
        "specularSHA256": specular_hash,
    }


def _jsc_tri_license_texts(project_root: Path) -> tuple[tuple[Path, str, Path], ...]:
    sources = (
        (JSC_MPL11_SOURCE, JSC_MPL11_SHA256, JSC_MPL11_DESTINATION),
        (JSC_GPL2_SOURCE, JSC_GPL2_SHA256, JSC_GPL2_DESTINATION),
    )
    for relative, digest, _destination in sources:
        source = _physical_path_beneath(
            project_root, relative, label=f"pinned JavaScriptCore license text {relative}")
        if sha256_file(source) != digest:
            raise NoticeError(f"pinned JavaScriptCore license text SHA-256 mismatch: {relative.name}")
    return tuple((project_root / relative, digest, destination)
                 for relative, digest, destination in sources)


def _jsc_headerless_bsd2_sources(project_root: Path) -> tuple[Path, Path, dict]:
    """Load the exact BSD-2 text and bounded 32-input JSC terms review."""
    license_path = _physical_path_beneath(
        project_root, JSC_HEADERLESS_BSD2_LICENSE_SOURCE,
        label="pinned JavaScriptCore BSD-2 license text")
    review_path = _physical_path_beneath(
        project_root, JSC_HEADERLESS_BSD2_REVIEW_SOURCE,
        label="pinned JavaScriptCore headerless-input terms review")
    if sha256_file(license_path) != JSC_HEADERLESS_BSD2_LICENSE_SHA256:
        raise NoticeError("pinned JavaScriptCore BSD-2 license SHA-256 mismatch")
    if sha256_file(review_path) != JSC_HEADERLESS_BSD2_REVIEW_SHA256:
        raise NoticeError("pinned JavaScriptCore headerless-input review SHA-256 mismatch")
    try:
        review = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("JavaScriptCore headerless-input review is invalid JSON") from error
    rows = review.get("rows")
    counts = review.get("counts", {})
    binding = review.get("sourceBinding", {})
    paths = [row.get("path") for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []
    hashes_valid = all(
        isinstance(row, dict)
        and isinstance(row.get("path"), str)
        and row["path"].startswith("WebKit/Source/JavaScriptCore/")
        and isinstance(row.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) is not None
        and type(row.get("bytes")) is int and row["bytes"] >= 0
        and row.get("binding") == "MATCH"
        for row in rows
    ) if isinstance(rows, list) else False
    if (review.get("schemaVersion") != 1
            or review.get("status") != "PARTIAL_ROW_HISTORY_CLASSIFICATION"
            or "classified as BSD-2-Clause" not in review.get("decision", "")
            or "Per-file copyright attribution" not in review.get("decision", "")
            or len(rows) != 32 or len(set(paths)) != 32 or not hashes_valid
            or counts.get("headerlessInputs") != 32
            or counts.get("rowsWithHashMatch") != 32
            or counts.get("rowsWithParsedHistory") != 32
            or counts.get("classifiedBSD2") != 32
            or counts.get("stillUnclassified") != 0
            or binding.get("upstreamCommit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or binding.get("sourceArchiveSHA256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or binding.get("webkitPatchSHA256") != "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
            or binding.get("runtimeImageSHA256") != JSC_HEADERLESS_BSD2_IMAGE_SHA256
            or review.get("licenseText", {}).get("sha256") != JSC_HEADERLESS_BSD2_LICENSE_SHA256
            or review.get("licenseText", {}).get("path") !=
                "notices/webrtc-v20-notices-candidate-v3/files/Source/WebCore/LICENSE-APPLE"
            or review.get("portabilityCorrection", {}).get("originalReviewSHA256") !=
                JSC_HEADERLESS_BSD2_ORIGINAL_REVIEW_SHA256
            or review.get("portabilityCorrection", {}).get("changedFields") != ["licenseText.path"]):
        raise NoticeError("JavaScriptCore headerless-input review scope or binding mismatch")
    return license_path, review_path, review


def _jsc_headerless_bsd2_image(runtime_frameworks: Path, review: dict) -> Path:
    relative = Path("JavaScriptCore.framework/Versions/A/JavaScriptCore")
    image = _physical_path_beneath(runtime_frameworks, relative,
                                   label="pinned JavaScriptCore runtime image")
    expected = review["sourceBinding"]["runtimeImageSHA256"]
    if (_runtime_image_build_sha(runtime_frameworks, relative, expected)
            != _current_runtime_hash(relative, expected)):
        raise NoticeError("JavaScriptCore headerless-input review does not match runtime image")
    with image.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("JavaScriptCore runtime image is not Mach-O")
    return image


def render_jsc_headerless_bsd2_markdown(image_sha256: str, review_sha256: str) -> str:
    return (
        f"{JSC_HEADERLESS_BSD2_SECTION_MARKER}\n\n"
        "The exact Apple BSD-2 text and pinned source-history review are included for 32 "
        "JavaScriptCore generator inputs without source headers. The maintainer review classifies "
        "those inputs as WebKit BSD-2 contributions from their exact source hashes and upstream "
        "history. This is a scoped input notice only.\n\n"
        f"- Pinned WebKit build image: `JavaScriptCore.framework/Versions/A/JavaScriptCore`; SHA-256 `{image_sha256}`.\n"
        f"- License text: `NeAntikRuntimeLicenses/JavaScriptCore/Apple-BSD-2-Clause.txt`; SHA-256 `{JSC_HEADERLESS_BSD2_LICENSE_SHA256}`.\n"
        f"- 32-input review: `NeAntikRuntimeLicenses/JavaScriptCore/HeaderlessInputsBSD2Review.json`; SHA-256 `{review_sha256}`.\n\n"
        "Per-file copyright attribution and complete JavaScriptCore image terms remain open; this "
        "notice does not qualify the full image or close corresponding-source and relinking obligations.\n"
    )


def render_jsc_headerless_bsd2_html(image_sha256: str, review_sha256: str) -> str:
    return (
        f'{JSC_HEADERLESS_BSD2_HTML_MARKER}\n'
        '<h2>JavaScriptCore headerless generator-input BSD-2 notice</h2>\n'
        '<p>The exact Apple BSD-2 text and pinned source-history review are included for 32 '
        'JavaScriptCore generator inputs without source headers. The maintainer review classifies '
        'those inputs as WebKit BSD-2 contributions from their exact source hashes and upstream '
        'history. This is a scoped input notice only.</p>\n'
        '<ul><li>Pinned WebKit build image: <code>JavaScriptCore.framework/Versions/A/JavaScriptCore</code>; '
        f'SHA-256 <code>{image_sha256}</code></li>'
        '<li>License text: <code>NeAntikRuntimeLicenses/JavaScriptCore/Apple-BSD-2-Clause.txt</code>; '
        f'SHA-256 <code>{JSC_HEADERLESS_BSD2_LICENSE_SHA256}</code></li>'
        '<li>32-input review: <code>NeAntikRuntimeLicenses/JavaScriptCore/HeaderlessInputsBSD2Review.json</code>; '
        f'SHA-256 <code>{review_sha256}</code></li></ul>\n'
        '<p>Per-file copyright attribution and complete JavaScriptCore image terms remain open; this '
        'notice does not qualify the full image or close corresponding-source and relinking obligations.</p>\n'
        '</section>'
    )


def _jsc_generated_output_notices(
    project_root: Path, runtime_frameworks: Path | None,
) -> tuple[Path, Path, dict]:
    """Load generated-output copyright blocks bound to the exact JSC image."""
    manifest_path = _physical_path_beneath(
        project_root, JSC_GENERATED_OUTPUT_MANIFEST_SOURCE,
        label="pinned JavaScriptCore generated-output notice manifest")
    headers_path = _physical_path_beneath(
        project_root, JSC_GENERATED_OUTPUT_HEADERS_SOURCE,
        label="pinned JavaScriptCore generated-output copyright blocks")
    if sha256_file(manifest_path) != JSC_GENERATED_OUTPUT_MANIFEST_SHA256:
        raise NoticeError("JavaScriptCore generated-output manifest SHA-256 mismatch")
    if sha256_file(headers_path) != JSC_GENERATED_OUTPUT_HEADERS_SHA256:
        raise NoticeError("JavaScriptCore generated-output headers SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        lineage_path = _physical_path_beneath(
            project_root, JSC_GENERATED_LINEAGE_SOURCE,
            label="pinned JavaScriptCore generator lineage")
        if sha256_file(lineage_path) != JSC_GENERATED_LINEAGE_SHA256:
            raise NoticeError("JavaScriptCore generated-input lineage SHA-256 mismatch")
        lineage = json.loads(lineage_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("JavaScriptCore generated-output evidence is invalid") from error
    rows = manifest.get("outputs")
    bundle = manifest.get("headerBundle", {})
    lineage_rows = lineage.get("generatedOutputs")
    manifest_outputs = [
        {key: row.get(key) for key in ("outputPath", "sourceGroup", "generatorRule", "outputSHA256")}
        for row in rows if isinstance(row, dict)
    ] if isinstance(rows, list) else []
    expected_outputs = [
        {"outputPath": row.get("output"), "sourceGroup": row.get("sourceGroup"),
         "generatorRule": row.get("generatorRule"), "outputSHA256": row.get("sha256")}
        for row in lineage_rows if isinstance(row, dict)
    ] if isinstance(lineage_rows, list) else []
    text = headers_path.read_text(encoding="utf-8")
    blocks = re.findall(
        r"^===== (.*?) =====\nSHA-256: ([0-9a-f]{64})\n"
        r"Exact initial generated-source copyright/license block follows\.\n\n"
        r"(.*?)(?=\n===== |\Z)", text, re.M | re.S)
    block_map = {(path, output_hash): header.rstrip() + "\n"
                 for path, output_hash, header in blocks}
    headers_valid = all(
        isinstance(row, dict)
        and isinstance(row.get("headerSHA256"), str)
        and block_map.get((row.get("outputPath"), row.get("outputSHA256"))) is not None
        and hashlib.sha256(block_map[(row["outputPath"], row["outputSHA256"])]
                           .encode("utf-8")).hexdigest() == row["headerSHA256"]
        for row in rows
    ) if isinstance(rows, list) else False
    if (manifest.get("schemaVersion") != 1
            or len(rows) != 6
            or manifest_outputs != expected_outputs
            or len(blocks) != 6 or len(block_map) != 6 or not headers_valid
            or manifest.get("sourceArchiveSHA256") != lineage.get("pinnedInputs", {}).get("sourceArchiveSHA256")
            or manifest.get("webkitPatchSHA256") != lineage.get("pinnedInputs", {}).get("webkitPatchSHA256")
            or manifest.get("generatorLineage", {}).get("sha256") != JSC_GENERATED_LINEAGE_SHA256
            or bundle.get("sha256") != JSC_GENERATED_OUTPUT_HEADERS_SHA256
            or bundle.get("bytes") != headers_path.stat().st_size
            or manifest.get("runtimeImage", {}).get("path") != "JavaScriptCore.framework/Versions/A/JavaScriptCore"
            or manifest.get("runtimeImage", {}).get("sha256") != JSC_HEADERLESS_BSD2_IMAGE_SHA256):
        raise NoticeError("JavaScriptCore generated-output notice scope or binding mismatch")
    return manifest_path, headers_path, manifest


def render_jsc_generated_output_markdown(manifest: dict) -> str:
    rows = manifest["outputs"]
    entries = "\n".join(
        f"- `{row['outputPath']}` — SHA-256 `{row['outputSHA256']}`; "
        f"{row['sourceGroup']} generated-source header."
        for row in rows)
    return (
        f"{JSC_GENERATED_OUTPUT_SECTION_MARKER}\n\n"
        "Exact initial copyright/license blocks from the six hash-bound JavaScriptCore generated "
        "C++ outputs are included below and in the adjacent manifest. The generator lineage and "
        "runtime image hashes are pinned; this records notices visible in generated outputs and "
        "does not close attribution for the 32 headerless generator inputs.\n\n"
        f"{entries}\n\n"
        f"- Notice blocks: `NeAntikRuntimeLicenses/JavaScriptCore/GeneratedOutputHeaders/GeneratedOutputHeaders.txt` "
        f"(SHA-256 `{JSC_GENERATED_OUTPUT_HEADERS_SHA256}`).\n"
        f"- Manifest: `NeAntikRuntimeLicenses/JavaScriptCore/GeneratedOutputHeaders/Manifest.json` "
        f"(SHA-256 `{JSC_GENERATED_OUTPUT_MANIFEST_SHA256}`).\n"
    )


def render_jsc_generated_output_html(manifest: dict) -> str:
    rows = "".join(
        f"<li><code>{html.escape(row['outputPath'])}</code> — SHA-256 "
        f"<code>{row['outputSHA256']}</code>; {html.escape(row['sourceGroup'])} generated source</li>"
        for row in manifest["outputs"])
    return (
        f'{JSC_GENERATED_OUTPUT_HTML_MARKER}\n'
        '<h2>JavaScriptCore generated-output copyright and license headers</h2>\n'
        '<p>Exact initial copyright/license blocks from six hash-bound JavaScriptCore generated '
        'C++ outputs are included below and in the adjacent manifest. This records notices visible '
        'in generated outputs and does not close attribution for the 32 headerless generator inputs.</p>\n'
        f'<ul>{rows}</ul>\n'
        '<ul><li>Notice blocks: '
        '<code>NeAntikRuntimeLicenses/JavaScriptCore/GeneratedOutputHeaders/GeneratedOutputHeaders.txt</code>; '
        f'SHA-256 <code>{JSC_GENERATED_OUTPUT_HEADERS_SHA256}</code></li>'
        '<li>Manifest: '
        '<code>NeAntikRuntimeLicenses/JavaScriptCore/GeneratedOutputHeaders/Manifest.json</code>; '
        f'SHA-256 <code>{JSC_GENERATED_OUTPUT_MANIFEST_SHA256}</code></li></ul>\n'
        '</section>'
    )


def _jsc_unicode_sources(project_root: Path) -> tuple[Path, Path]:
    license_path = _physical_path_beneath(
        project_root, JSC_UNICODE_LICENSE_SOURCE,
        label="pinned Unicode License v3 text")
    lineage_path = _physical_path_beneath(
        project_root, JSC_GENERATED_LINEAGE_SOURCE,
        label="pinned JavaScriptCore generated-input lineage")
    if sha256_file(license_path) != JSC_UNICODE_LICENSE_SHA256:
        raise NoticeError("pinned Unicode License v3 SHA-256 mismatch")
    if sha256_file(lineage_path) != JSC_GENERATED_LINEAGE_SHA256:
        raise NoticeError("pinned JavaScriptCore generated-input lineage SHA-256 mismatch")
    try:
        lineage = json.loads(lineage_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("JavaScriptCore generated-input lineage is invalid JSON") from error
    inputs = {row.get("path"): row for row in lineage.get("inputRecords", [])
              if isinstance(row, dict)}
    outputs = {row.get("sourceGroup"): row for row in lineage.get("generatedOutputs", [])
               if isinstance(row, dict)}
    groups = lineage.get("generatorGroups", {})
    pinned = lineage.get("pinnedInputs", {})
    case_folding = inputs.get("WebKit/Source/JavaScriptCore/ucd/CaseFolding.txt", {})
    yarr = outputs.get("yarr", {})
    yarr_group = groups.get("yarr", {})
    if (pinned.get("sourceArchiveSHA256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or case_folding.get("sha256") != "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"
            or yarr.get("sha256") != "f014f6e3a42b46da22d17832d688f39d07999bf0295bbee472fc039fcf66af22"
            or "WebKit/Source/JavaScriptCore/ucd/CaseFolding.txt"
            not in yarr_group.get("sourcePaths", [])):
        raise NoticeError("JavaScriptCore Unicode CaseFolding lineage binding mismatch")
    return license_path, lineage_path


def render_jsc_unicode_markdown() -> str:
    return (
        f"{JSC_UNICODE_SECTION_MARKER}\n\n"
        "The pinned WebKit 43d5b8d85e2e5eed41d7ff8a79da831bf405be6c source uses Unicode "
        "17.0.0 `Source/JavaScriptCore/ucd/CaseFolding.txt` to generate "
        "`YarrCanonicalizeUnicode.cpp`. The generator lineage records the exact input and output "
        "hashes, pinned source archive, patch, and CMake rule.\n\n"
        f"- Unicode data input SHA-256: `ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.\n"
        f"- Generated output SHA-256: `f014f6e3a42b46da22d17832d688f39d07999bf0295bbee472fc039fcf66af22`.\n"
        f"- Unicode License v3: `NeAntikRuntimeLicenses/JavaScriptCore/Unicode-License-V3.txt` "
        f"(SHA-256 `{JSC_UNICODE_LICENSE_SHA256}`); Copyright © 2025 Unicode, Inc.\n"
        f"- Source lineage: `NeAntikRuntimeLicenses/JavaScriptCore/GeneratedInputLineage.json` "
        f"(SHA-256 `{JSC_GENERATED_LINEAGE_SHA256}`).\n\n"
        "The Unicode notice is included with the application. This source mapping does not resolve "
        "the remaining per-image license, corresponding-source, or relinking decisions.\n"
    )


def render_jsc_unicode_html() -> str:
    return (
        f'{JSC_UNICODE_HTML_MARKER}\n'
        '<h2>JavaScriptCore Unicode CaseFolding generated-input notice</h2>\n'
        '<p>WebKit 43d5b8d85e2e5eed41d7ff8a79da831bf405be6c uses Unicode 17.0.0 '
        '<code>Source/JavaScriptCore/ucd/CaseFolding.txt</code> to generate '
        '<code>YarrCanonicalizeUnicode.cpp</code>. The pinned lineage binds the input, output, '
        'source archive, patch, and CMake rule.</p>\n'
        '<ul><li>Input SHA-256: <code>ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183</code></li>'
        '<li>Output SHA-256: <code>f014f6e3a42b46da22d17832d688f39d07999bf0295bbee472fc039fcf66af22</code></li>'
        f'<li>Unicode License v3: <code>NeAntikRuntimeLicenses/JavaScriptCore/Unicode-License-V3.txt</code> '
        f'(SHA-256 <code>{JSC_UNICODE_LICENSE_SHA256}</code>); Copyright © 2025 Unicode, Inc.</li>'
        f'<li>Lineage: <code>NeAntikRuntimeLicenses/JavaScriptCore/GeneratedInputLineage.json</code> '
        f'(SHA-256 <code>{JSC_GENERATED_LINEAGE_SHA256}</code>)</li></ul>\n'
        '<p>This source mapping does not resolve remaining per-image license, corresponding-source, '
        'or relinking decisions.</p>\n</section>'
    )


def _angle_notice_sources(project_root: Path) -> tuple[tuple[Path, str, str, Path], ...]:
    sources = (
        (ANGLE_LICENSE_SOURCE, ANGLE_LICENSE_NAME, ANGLE_LICENSE_SHA256,
         ANGLE_LICENSE_DESTINATION),
        (XXHASH_LICENSE_SOURCE, XXHASH_LICENSE_NAME, XXHASH_LICENSE_SHA256,
         XXHASH_LICENSE_DESTINATION),
        (CHROMIUM_ANGLE_LICENSE_SOURCE, CHROMIUM_ANGLE_LICENSE_NAME,
         CHROMIUM_ANGLE_LICENSE_SHA256, CHROMIUM_ANGLE_LICENSE_DESTINATION),
    )
    for relative, _name, expected_hash, _destination in sources:
        source = project_root / relative
        _physical_file(source, label=f"pinned WebKit license text: {relative}")
        if sha256_file(source) != expected_hash:
            raise NoticeError(f"pinned WebKit license SHA-256 mismatch: {relative}")
    return sources


def _webinspector_notice_sources(project_root: Path, runtime_frameworks: Path | None) -> None:
    framework_license = _physical_path_beneath(
        project_root, WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE,
        label="pinned WebInspectorUI framework source-file license")
    if sha256_file(framework_license) != WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256:
        raise NoticeError("pinned WebInspectorUI framework license SHA-256 mismatch")
    for name, digest, size in WEBINSPECTOR_LICENSES:
        source_relative = Path("docs/evidence/third-party/webinspector") / name / "LICENSE"
        source = _physical_path_beneath(project_root, source_relative,
                                        label=f"pinned WebInspectorUI source license {name}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebInspectorUI source license hash/size mismatch: {name}")
        if runtime_frameworks is not None:
            bundled_relative = (Path("WebInspectorUI.framework/Versions/A/Resources/External")
                                / name / "LICENSE")
            bundled = _physical_path_beneath(runtime_frameworks, bundled_relative,
                                             label=f"bundled WebInspectorUI license {name}")
            if bundled.stat().st_size != size or sha256_file(bundled) != digest:
                raise NoticeError(f"bundled WebInspectorUI license hash/size mismatch: {name}")


def render_webinspector_markdown() -> str:
    lines = [WEBINSPECTOR_SECTION_MARKER, "",
             "These four external license texts are included in the pinned WebInspectorUI framework resources.",
             "Each source path and bundled path below has identical hash-pinned bytes.", ""]
    for name, digest, _size in WEBINSPECTOR_LICENSES:
        lines.append(f"- `{name}`: upstream `Source/WebInspectorUI/UserInterface/External/{name}/LICENSE`; "
                     f"bundled `WebInspectorUI.framework/Versions/A/Resources/External/{name}/LICENSE`; "
                     f"SHA-256 `{digest}`.")
    lines.extend(["", "This is a factual resource index. Governing terms, complete notice coverage, "
                  "and redistribution review remain open."])
    return "\n".join(lines) + "\n"


def render_webinspector_html() -> str:
    rows = "\n".join(
        "<tr><td><code>" + html.escape(name) + "</code></td><td><code>" +
        html.escape(f"Source/WebInspectorUI/UserInterface/External/{name}/LICENSE") +
        "</code></td><td><code>" +
        html.escape(f"WebInspectorUI.framework/Versions/A/Resources/External/{name}/LICENSE") +
        f"</code></td><td><code>{digest}</code></td></tr>"
        for name, digest, _size in WEBINSPECTOR_LICENSES
    )
    return (f"{WEBINSPECTOR_HTML_MARKER}\n"
            "<h2>Bundled WebInspectorUI external license resources</h2>\n"
            "<p>Four source texts match the pinned framework resources by path and hash.</p>\n"
            "<table><thead><tr><th>Component</th><th>Upstream path</th>"
            "<th>Bundled path</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{rows}\n</tbody></table>\n"
            "<p>This resource index does not establish governing terms, complete "
            "notice coverage, or redistribution approval.</p>\n</section>")


def render_webinspector_framework_markdown() -> str:
    return (f"{WEBINSPECTOR_FRAMEWORK_SECTION_MARKER}\n\n"
            "The following BSD-2-Clause notice is reproduced for the single "
            "source input `Source/WebInspectorUI/WebInspectorUI.cpp` "
            "(source SHA-256 `57893c96cec431ef5fc1f7bef7728980769140e96a776f528aa6de7319b37b07`). "
            "It is not a framework-wide license determination. The complete text is "
            f"packaged at `{WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION.as_posix()}` "
            f"(SHA-256 `{WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256}`).")


def render_webinspector_framework_html() -> str:
    return (f"{WEBINSPECTOR_FRAMEWORK_HTML_MARKER}\n"
            "<h2>WebInspectorUI source-file notice</h2>\n"
            "<p>This BSD-2-Clause notice is reproduced for the single source input "
            "<code>Source/WebInspectorUI/WebInspectorUI.cpp</code> "
            "(SHA-256 <code>57893c96cec431ef5fc1f7bef7728980769140e96a776f528aa6de7319b37b07</code>). "
            "This is not a framework-wide license determination. The complete text is "
            f"packaged at <code>{html.escape(WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION.as_posix())}</code> "
            f"(SHA-256 <code>{WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256}</code>).</p>\n</section>")


def _webkit_xpc_entrypoint_notice(project_root: Path) -> tuple[Path, dict[str, object], bytes]:
    manifest_path = _physical_path_beneath(
        project_root, WEBKIT_XPC_ENTRYPOINT_MAP,
        label="pinned WebKit XPC entrypoint source map")
    if sha256_file(manifest_path) != WEBKIT_XPC_ENTRYPOINT_MAP_SHA256:
        raise NoticeError("pinned WebKit XPC entrypoint map SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise NoticeError("invalid WebKit XPC entrypoint map") from error
    source_path = "Source/WebKit/Shared/EntryPointUtilities/Cocoa/AuxiliaryProcessMain.cpp"
    images = manifest.get("runtimeImages") if isinstance(manifest, dict) else None
    if (not isinstance(manifest, dict)
            or manifest.get("schemaVersion") != 1
            or manifest.get("upstreamCommit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or manifest.get("sourcePath") != source_path
            or manifest.get("sourceSHA256") != "5363ad87e3e7049a31497f886ba8e8af496dcee316845997b31592d79ed44755"
            or manifest.get("headerNoticePath") != WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE.as_posix()
            or manifest.get("headerNoticeSHA256") != WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256
            or manifest.get("distributionDestination") != WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION.as_posix()
            or not isinstance(images, list) or len(images) != 5
            or any(not isinstance(row, dict)
                   or row.get("sourcePath") != source_path
                   or row.get("sourceSHA256") != manifest.get("sourceSHA256")
                   or not isinstance(row.get("runtimePath"), str)
                   or not isinstance(row.get("runtimeSHA256"), str)
                   for row in images)):
        raise NoticeError("pinned WebKit XPC entrypoint map has unexpected scope")
    source = _physical_path_beneath(
        project_root, WEBKIT_XPC_ENTRYPOINT_NOTICE_SOURCE,
        label="pinned WebKit XPC entrypoint BSD notice")
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256:
        raise NoticeError("pinned WebKit XPC entrypoint BSD notice SHA-256 mismatch")
    return source, manifest, data


def render_webkit_xpc_entrypoint_markdown(manifest: dict[str, object]) -> str:
    images = manifest["runtimeImages"]
    assert isinstance(images, list)
    rows = "\n".join(f"- `{row['runtimePath']}` (SHA-256 `{_current_runtime_hash(row['runtimePath'], row['runtimeSHA256'])}`)"
                      for row in images)
    return (f"{WEBKIT_XPC_ENTRYPOINT_SECTION_MARKER}\n\n"
            "The included BSD-2-Clause source-header notice applies to the shared "
            "WebKit XPC entrypoint input `Source/WebKit/Shared/EntryPointUtilities/Cocoa/"
            "AuxiliaryProcessMain.cpp` (source SHA-256 `"
            f"{manifest['sourceSHA256']}`). The pinned source map associates that input "
            f"with these five runtime images:\n{rows}\n\n"
            "This source-input mapping is technical provenance, not a full dependency "
            "license determination or redistribution approval. The complete notice is "
            f"packaged at `{WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION.as_posix()}` "
            f"(SHA-256 `{WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256}`).")


def render_webkit_xpc_entrypoint_html(manifest: dict[str, object]) -> str:
    images = manifest["runtimeImages"]
    assert isinstance(images, list)
    rows = "\n".join(f"<li><code>{html.escape(row['runtimePath'])}</code> "
                      f"(SHA-256 <code>{html.escape(_current_runtime_hash(row['runtimePath'], row['runtimeSHA256']))}</code>)</li>"
                      for row in images)
    return (f"{WEBKIT_XPC_ENTRYPOINT_HTML_MARKER}\n"
            "<h2>WebKit XPC process entrypoint source notice</h2>\n"
            "<p>The included BSD-2-Clause source-header notice applies to the shared "
            "input <code>Source/WebKit/Shared/EntryPointUtilities/Cocoa/"
            "AuxiliaryProcessMain.cpp</code> (source SHA-256 <code>"
            f"{manifest['sourceSHA256']}</code>). The pinned source map associates it "
            "with these five runtime images:</p><ul>\n"
            f"{rows}\n</ul><p>This is technical provenance for a source input, not a full "
            "dependency license determination or redistribution approval. The complete "
            f"notice is packaged at <code>{html.escape(WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION.as_posix())}</code> "
            f"(SHA-256 <code>{WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256}</code>).</p>\n</section>")


def _sandbox_notice_sources(project_root: Path) -> tuple[tuple[str, str, str, int], ...]:
    manifest_path = _physical_path_beneath(
        project_root, SANDBOX_SOURCE_ROOT / "MANIFEST.json",
        label="pinned WebKit sandbox notice manifest")
    if sha256_file(manifest_path) != SANDBOX_MANIFEST_SHA256:
        raise NoticeError("pinned WebKit sandbox notice manifest SHA-256 mismatch")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise NoticeError("invalid WebKit sandbox notice manifest") from error
    if not isinstance(manifest, dict):
        raise NoticeError("invalid WebKit sandbox notice manifest")
    rows = manifest.get("rows")
    if (manifest.get("schemaVersion") != 1
            or manifest.get("pinnedWebKitCommit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or manifest.get("patchedSources") != [{
                "sourcePath": "Source/WebKit/WebProcess/com.apple.WebProcess.sb.in",
                "patchSHA256": "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735",
            }]
            or not isinstance(rows, list) or len(rows) != 6):
        raise NoticeError("invalid WebKit sandbox notice manifest")
    result = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"sourcePath", "copiedPath", "runtimePath", "sha256", "bytes"}:
            raise NoticeError("invalid WebKit sandbox notice row")
        name, source_path, runtime_path = (row[key] for key in
                                           ("copiedPath", "sourcePath", "runtimePath"))
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", name)
                or name in seen or not isinstance(source_path, str)
                or not source_path.startswith("Source/")
                or not isinstance(runtime_path, str)
                or not runtime_path.endswith(".sb")
                or not isinstance(row["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
                or type(row["bytes"]) is not int or row["bytes"] <= 0):
            raise NoticeError("invalid WebKit sandbox notice row")
        seen.add(name)
        source = _physical_path_beneath(
            project_root, SANDBOX_SOURCE_ROOT / name,
            label=f"pinned WebKit sandbox source {name}")
        if source.stat().st_size != row["bytes"] or sha256_file(source) != row["sha256"]:
            raise NoticeError(f"pinned WebKit sandbox source hash/size mismatch: {name}")
        result.append((name, source_path, runtime_path, row["bytes"]))
    return tuple(result)


def _source_crosswalk_binding(
    project_root: Path, source_offer_root: Path | None,
) -> tuple[Path, str, dict | None]:
    """Resolve the crosswalk from the exact offer, retaining the V20 fallback."""
    if source_offer_root is None:
        path = _physical_path_beneath(
            project_root, SOURCE_CROSSWALK, label="pinned WebKit source/license crosswalk")
        return path, SOURCE_CROSSWALK_SHA256, None
    if source_offer_root.is_symlink() or not source_offer_root.is_dir():
        raise NoticeError("pinned WebKit source offer is not a physical directory")
    source_offer_root = source_offer_root.resolve(strict=True)
    manifest_path = source_offer_root / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise NoticeError("pinned WebKit source-offer manifest is unavailable")
    try:
        offer = json.loads(manifest_path.read_text(encoding="utf-8"))
        binding = offer.get("currentWebKitV382FilteredModelSource")
        if binding is None:
            path = _physical_path_beneath(
                project_root, SOURCE_CROSSWALK, label="pinned WebKit source/license crosswalk")
            return path, SOURCE_CROSSWALK_SHA256, None
        if not isinstance(binding, dict):
            raise ValueError("filtered crosswalk binding")
        component_by_path = {row["path"]: row for row in offer["sourceOfferComponents"]}
        relative = Path(binding["crosswalkPath"])
        provenance_relative = Path(binding["provenancePath"])
        archive_relative = Path(offer["componentBoundaries"]["webkitSourceArchive"])
        if any(path.is_absolute() or ".." in path.parts
               for path in (relative, provenance_relative, archive_relative)):
            raise ValueError("unsafe filtered component path")
        expected_crosswalk = binding["crosswalkSHA256"]
        expected_provenance = binding["provenanceSHA256"]
        expected_archive = binding["derivedArchiveSHA256"]
        scope_patch_relative = Path(binding["scopePatchPath"])
        if scope_patch_relative.is_absolute() or ".." in scope_patch_relative.parts:
            raise ValueError("unsafe filtered scope patch path")
        expected_components = (
            (relative.as_posix(), expected_crosswalk),
            (provenance_relative.as_posix(), expected_provenance),
            (archive_relative.as_posix(), expected_archive),
            (scope_patch_relative.as_posix(), V382_FILTERED_MODEL_SCOPE_PATCH_SHA256),
            ("patches/webkit-text-extraction-filter-macos-deployment-gate-v377.patch",
             V377_TEXT_EXTRACTION_PATCH_SHA256),
            ("patches/webkit-coreprediction-model-macos-deployment-gate-v381.patch",
             V381_CORE_PREDICTION_PATCH_SHA256),
        )
        for rel, expected in expected_components:
            row = component_by_path.get(rel)
            path = _physical_path_beneath(
                source_offer_root, Path(rel), label=f"filtered source-offer component {rel}")
            if (row is None or row.get("includedInOfferFolder") is not True
                    or row.get("bytes") != path.stat().st_size
                    or row.get("sha256") != expected or sha256_file(path) != expected):
                raise ValueError("filtered offer component does not match its binding")
        crosswalk_path = source_offer_root / relative
        crosswalk = json.loads(crosswalk_path.read_text(encoding="utf-8"))
        provenance = json.loads((source_offer_root / provenance_relative).read_text(encoding="utf-8"))
        omitted = {
            "Source/WebKit/Resources/TextExtractionFilter.mlmodel":
                "87a4e82b476fb7e61482c243230fffa319b5108319167f340db5ff8e9d48693f",
            "Source/WebKit/Resources/ResourceLoadStatistics/corePrediction_model":
                "221555a2cdd2e957f18d478c4b9fd01f308c1613e6e10840cce924e5f543091a",
        }
        excluded_rows = crosswalk["excludedRuntimeRows"]
        excluded_sources = {
            source["path"]: source["sha256"]
            for row in excluded_rows["sourceRows"]
            for source in row["mappedSources"]
        }
        provenance_exclusions = {
            row.get("path", "").removeprefix("WebKit/"): row.get("sha256")
            for row in provenance.get("excludedSourceAssets", [])
            if isinstance(row, dict)
        }
        expected_patch_paths = [row[0] for row in expected_components[4:]] + [
            scope_patch_relative.as_posix()]
        if (crosswalk.get("filteredSourceOffer", {}).get("archiveSHA256") != expected_archive
                or crosswalk.get("filteredSourceOffer", {}).get("excludedSourcePaths") != sorted(omitted)
                or excluded_rows.get("count") != 4
                or excluded_rows.get("status") != "UNKNOWN until exact full-build and staged-candidate absence proof"
                or excluded_sources != omitted
                or provenance_exclusions != omitted
                or provenance.get("upstream", {}).get("archiveSHA256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
                or provenance.get("patches") != expected_patch_paths
                or binding.get("scopePatchSHA256") != V382_FILTERED_MODEL_SCOPE_PATCH_SHA256
                or provenance.get("derivedArchive", {}).get("sha256") != expected_archive
                or provenance.get("status") != "DERIVED_FROM_PINNED_UPSTREAM_ARCHIVE; BUILD_AND_RUNTIME_ABSENCE_UNPROVEN"):
            raise ValueError("filtered crosswalk/provenance scope mismatch")
        crosswalk["crosswalkSHA256"] = expected_crosswalk
        return crosswalk_path, expected_crosswalk, crosswalk
    except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
        raise NoticeError("filtered source-offer crosswalk binding is invalid") from error


def _verify_excluded_model_runtime_absence(
    runtime_frameworks: Path, crosswalk: dict | None,
) -> None:
    """Require all omitted model outputs to be absent from the exact staged runtime."""
    if crosswalk is None:
        return
    excluded = crosswalk.get("excludedRuntimeRows")
    rows = excluded.get("sourceRows") if isinstance(excluded, dict) else None
    if not isinstance(rows, list) or len(rows) != 4:
        raise NoticeError("filtered model-runtime exclusion map is invalid")
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("owned WebKit Frameworks root must be a physical directory")
    runtime_frameworks = runtime_frameworks.resolve(strict=True)
    expected = {
        "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/analytics/coremldata.bin",
        "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/coremldata.bin",
        "WebKit.framework/Versions/A/Resources/TextExtractionFilter.mlmodelc/metadata.json",
        "WebKit.framework/Versions/A/Resources/corePrediction_model",
    }
    actual = {row.get("runtimePath") for row in rows if isinstance(row, dict)}
    if actual != expected:
        raise NoticeError("filtered model-runtime exclusion paths differ from the pinned scope")
    for relative in expected:
        path = runtime_frameworks / relative
        current = runtime_frameworks
        for part in Path(relative).parts:
            current = current / part
            if current.is_symlink():
                raise NoticeError("symlink encountered while verifying excluded model runtime")
        if path.exists():
            raise NoticeError("excluded model runtime resource is present in the staged candidate")


def _source_candidate_notice_sources(
    project_root: Path, source_offer_root: Path | None = None,
    runtime_frameworks: Path | None = None,
) -> tuple[dict, bytes, tuple[tuple[str, Path, str, int], ...]]:
    """Return exact license-text candidates whose source paths occur in build maps.

    The path association is technical evidence only. It intentionally does not
    decide which terms govern any binary or replace the source headers.
    """
    crosswalk_path, crosswalk_sha256, filtered_crosswalk = _source_crosswalk_binding(
        project_root, source_offer_root)
    if sha256_file(crosswalk_path) != crosswalk_sha256:
        raise NoticeError("pinned WebKit source/license crosswalk SHA-256 mismatch")
    if runtime_frameworks is not None:
        _verify_excluded_model_runtime_absence(runtime_frameworks, filtered_crosswalk)
    corpus_manifest_path = _physical_path_beneath(
        project_root, SOURCE_CORPUS_ROOT / "MANIFEST.json",
        label="pinned WebKit source license-text corpus manifest")
    if sha256_file(corpus_manifest_path) != SOURCE_CORPUS_MANIFEST_SHA256:
        raise NoticeError("pinned WebKit source license-text corpus manifest SHA-256 mismatch")
    try:
        crosswalk = json.loads(crosswalk_path.read_text(encoding="utf-8"))
        corpus = json.loads(corpus_manifest_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise NoticeError("pinned WebKit source/license crosswalk is invalid") from error
    commit = "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
    if (crosswalk.get("schemaVersion") != 1
            or crosswalk.get("status") != "technical-source-license-crosswalk;not-legal-applicability-or-release-approval"
            or crosswalk.get("upstream", {}).get("commit") != commit
            or crosswalk.get("candidateLicenseCorpus", {}).get("count") != 308
            or corpus.get("schemaVersion") != 1 or corpus.get("commit") != commit
            or corpus.get("sourcePatchSHA256") != "b33b9320bd8f3bae56eadebc738fe91d40f0cf77e89fd2885bf28679d2af0735"
            or not isinstance(corpus.get("entries"), list)
            or len(corpus["entries"]) != 308):
        raise NoticeError("pinned WebKit source/license manifests have an unexpected scope")

    selected: set[str] = set()
    for section, row_key in (("directCompileInputs", "sourceRows"),
                             ("webCoreUnityInputs", "sourceRows")):
        rows = crosswalk.get(section, {}).get(row_key)
        if not isinstance(rows, list):
            raise NoticeError("WebKit source/license crosswalk source rows are missing")
        for row in rows:
            candidates = row.get("ancestorLicenseTextCandidates") if isinstance(row, dict) else None
            if not isinstance(candidates, list):
                raise NoticeError("WebKit source/license crosswalk candidate list is invalid")
            selected.update(candidates)
    resources = crosswalk.get("runtimeResources", {}).get("sourceRows")
    if not isinstance(resources, list):
        raise NoticeError("WebKit source/license crosswalk resource rows are missing")
    for row in resources:
        mapped = row.get("mappedSources") if isinstance(row, dict) else None
        if not isinstance(mapped, list):
            raise NoticeError("WebKit source/license crosswalk mapped-source list is invalid")
        for source in mapped:
            candidates = source.get("ancestorLicenseTextCandidates") if isinstance(source, dict) else None
            if not isinstance(candidates, list):
                raise NoticeError("WebKit resource license candidate list is invalid")
            selected.update(candidates)
    if len(selected) != SOURCE_CANDIDATE_COUNT:
        raise NoticeError("WebKit source/license candidate set differs from the pinned crosswalk")

    entries = corpus["entries"]
    by_source = {row.get("sourcePath"): row for row in entries if isinstance(row, dict)}
    if len(by_source) != len(entries):
        raise NoticeError("WebKit source license corpus has duplicate paths")
    packed = []
    copied = []
    for source_path in sorted(selected):
        row = by_source.get(source_path)
        if not isinstance(row, dict):
            raise NoticeError(f"WebKit candidate license text is missing from corpus: {source_path}")
        relative = row.get("corpusPath")
        if (not isinstance(source_path, str) or not source_path.startswith("Source/")
                or not isinstance(relative, str) or "\\" in relative
                or Path(relative).is_absolute() or ".." in Path(relative).parts
                or not isinstance(row.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
                or type(row.get("bytes")) is not int or row["bytes"] <= 0):
            raise NoticeError("WebKit source license corpus entry is malformed")
        source = _physical_path_beneath(
            project_root / SOURCE_CORPUS_ROOT, Path(relative),
            label=f"pinned WebKit source license candidate {source_path}")
        if source.stat().st_size != row["bytes"] or sha256_file(source) != row["sha256"]:
            raise NoticeError(f"WebKit source license candidate hash/size mismatch: {source_path}")
        output = Path("files") / source_path
        packed.append({"sourcePath": source_path, "outputPath": output.as_posix(),
                       "sha256": row["sha256"], "bytes": row["bytes"]})
        copied.append((source_path, source, row["sha256"], row["bytes"]))
    manifest = {
        "schemaVersion": 1,
        "status": "technical source-path candidates; not a legal applicability decision",
        "upstreamCommit": commit,
        "sourcePatchSHA256": crosswalk["upstream"]["sourcePatchSHA256"],
        "crosswalkSHA256": crosswalk_sha256,
        "corpusManifestSHA256": SOURCE_CORPUS_MANIFEST_SHA256,
        "entryCount": len(packed),
        "entries": packed,
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return manifest, manifest_bytes, tuple(copied)


def _webkit_swift_source_notice_sources(
    project_root: Path,
) -> tuple[dict, bytes, tuple[tuple[str, Path, str, int], ...]]:
    """Load exact, hash-pinned source headers for mapped WebKitSwift inputs."""
    manifest_path = _physical_path_beneath(
        project_root, WEBKIT_SWIFT_MANIFEST_SOURCE,
        label="pinned WebKitSwift source-header manifest")
    if sha256_file(manifest_path) != WEBKIT_SWIFT_MANIFEST_SHA256:
        raise NoticeError("pinned WebKitSwift source-header manifest SHA-256 mismatch")
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("pinned WebKitSwift source-header manifest is invalid") from error
    expected_images = [
        {"path": "WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib",
         "sha256": "a30fe4e2947b08ea17c784218a2c833426be9040f52d136f29a9abd070044b41",
         "sourceInputCount": 32},
        {"path": "libWebKitSwift.dylib",
         "sha256": "a30fe4e2947b08ea17c784218a2c833426be9040f52d136f29a9abd070044b41",
         "sourceInputCount": 32},
    ]
    if (not isinstance(manifest, dict)
            or manifest.get("schemaVersion") != 1
            or manifest.get("status") != "exact source-header notices for two WebKitSwift runtime images"
            or manifest.get("upstreamCommit") != "43d5b8d85e2e5eed41d7ff8a79da831bf405be6c"
            or manifest.get("sourceArchiveSHA256") != "658ca48ecfdaa341991bc9cd773a0aa394dabe90ccd1851021433fbd9e72df9f"
            or manifest.get("sourceLineageEvidence") != "docs/evidence/webkit-v20-link-target-input-lineage-addendum-20261025.json"
            or manifest.get("sourceLineageSHA256") != "17cefa1d78f880a43322d7a2acde5010f366b7aebabe7c4adfcd59ce57aa5de2"
            or manifest.get("runtimeImages") != expected_images
            or manifest.get("licenseScope") != (
                "Every listed source input begins with an exact Apple BSD-2 notice. "
                "This manifest preserves those source notices; it does not decide the "
                "complete license composition of either linked image or its dependencies.")
            or manifest.get("entryCount") != 32
            or not isinstance(manifest.get("entries"), list)
            or len(manifest["entries"]) != 32):
        raise NoticeError("WebKitSwift source-header manifest has unexpected scope")
    lineage_path = _physical_path_beneath(
        project_root, Path(manifest["sourceLineageEvidence"]),
        label="pinned WebKitSwift source lineage evidence")
    if sha256_file(lineage_path) != manifest["sourceLineageSHA256"]:
        raise NoticeError("WebKitSwift source-lineage evidence SHA-256 mismatch")

    copied = []
    entries = []
    seen_sources: set[str] = set()
    seen_outputs: set[str] = set()
    for row in manifest["entries"]:
        if not isinstance(row, dict) or set(row) != {
                "sourcePath", "sourceSHA256", "sourceBytes",
                "headerSHA256", "headerBytes", "outputPath"}:
            raise NoticeError("WebKitSwift source-header manifest row is malformed")
        source_path = row["sourcePath"]
        output_path = row["outputPath"]
        if (not isinstance(source_path, str) or not source_path.startswith("Source/WebKit/")
                or "\\" in source_path or ".." in PurePosixPath(source_path).parts
                or not isinstance(output_path, str)
                or output_path != ("headers/" + source_path + ".LICENSE.txt")
                or source_path in seen_sources or output_path in seen_outputs
                or not re.fullmatch(r"[0-9a-f]{64}", str(row["sourceSHA256"]))
                or not re.fullmatch(r"[0-9a-f]{64}", str(row["headerSHA256"]))
                or type(row["sourceBytes"]) is not int or row["sourceBytes"] <= 0
                or type(row["headerBytes"]) is not int or row["headerBytes"] <= 0):
            raise NoticeError("WebKitSwift source-header manifest row is unsafe")
        seen_sources.add(source_path)
        seen_outputs.add(output_path)
        output = _physical_path_beneath(
            project_root, WEBKIT_SWIFT_SOURCE_NOTICE_ROOT / Path(output_path),
            label=f"pinned WebKitSwift source header {source_path}")
        if output.stat().st_size != row["headerBytes"] or sha256_file(output) != row["headerSHA256"]:
            raise NoticeError(f"WebKitSwift source-header hash/size mismatch: {source_path}")
        data = output.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeError as error:
            raise NoticeError(f"WebKitSwift source header is not UTF-8: {source_path}") from error
        if ("Redistribution and use in source and binary forms" not in text
                or "THIS SOFTWARE IS PROVIDED BY APPLE INC." not in text):
            raise NoticeError(f"WebKitSwift source header is not the expected Apple notice: {source_path}")
        copied.append((source_path, output, row["headerSHA256"], row["headerBytes"]))
        entries.append(row)
    if len(seen_sources) != 32:
        raise NoticeError("WebKitSwift source-header set is incomplete")
    return manifest, manifest_bytes, tuple(copied)


def _verify_webkit_swift_runtime_images(runtime_frameworks: Path, manifest: dict) -> None:
    """Bind the source-header index to the two exact WebKitSwift runtime images."""
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    for row in manifest["runtimeImages"]:
        relative = Path(row["path"])
        expected_sha256 = _current_runtime_hash(relative, row["sha256"])
        image = _physical_path_beneath(
            runtime_frameworks, relative,
            label=f"pinned WebKitSwift runtime image {row['path']}")
        if _runtime_image_build_sha(runtime_frameworks, relative,
                                    row["sha256"]) != expected_sha256:
            raise NoticeError(f"WebKitSwift runtime image SHA-256 mismatch: {row['path']}")
        with image.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                raise NoticeError(f"WebKitSwift runtime image is not Mach-O: {row['path']}")


def render_webkit_swift_source_markdown(
    manifest: dict, notices: tuple[tuple[str, Path, str, int], ...],
) -> str:
    lines = [WEBKIT_SWIFT_SECTION_MARKER, "",
             "Exact Apple BSD-2 source-header notices are preserved for 32 source inputs mapped to the two listed WebKitSwift images. This records source headers only; it does not determine the complete terms for either linked image or its dependencies.", ""]
    images = manifest["runtimeImages"]
    for image in images:
        image_sha256 = _current_runtime_hash(image["path"], image["sha256"])
        lines.append(f"- Runtime image `{image['path']}` (build-evidence SHA-256 `{image_sha256}`): {image['sourceInputCount']} mapped source inputs.")
    lines.append("")
    for row, (source_path, _source, digest, size) in zip(manifest["entries"], notices):
        lines.append(f"- `{source_path}` → `NeAntikRuntimeLicenses/WebKitSwift/{row['outputPath']}`; {size} bytes; SHA-256 `{digest}`.")
    lines.extend(["", "Source-header preservation is not a complete runtime license determination or release approval."])
    return "\n".join(lines) + "\n"


def render_webkit_swift_source_html(
    manifest: dict, notices: tuple[tuple[str, Path, str, int], ...],
) -> str:
    image_rows = "\n".join(
        "<tr><td><code>" + html.escape(row["path"]) + "</code></td><td><code>" +
        html.escape(_current_runtime_hash(row["path"], row["sha256"])) + f"</code></td><td>{row['sourceInputCount']}</td></tr>"
        for row in manifest["runtimeImages"])
    notice_rows = "\n".join(
        "<tr><td><code>" + html.escape(source_path) + "</code></td><td><code>" +
        html.escape("NeAntikRuntimeLicenses/WebKitSwift/" + row["outputPath"]) +
        f"</code></td><td>{size}</td><td><code>{digest}</code></td></tr>"
        for row, (source_path, _source, digest, size) in zip(manifest["entries"], notices))
    return (f"{WEBKIT_SWIFT_HTML_MARKER}\n<h2>WebKitSwift source-header notices</h2>\n"
            "<p>Exact Apple BSD-2 source-header notices are preserved for 32 source inputs mapped to the two listed images. This does not determine the complete license terms of either linked image or its dependencies.</p>\n"
            "<table><thead><tr><th>Runtime image</th><th>Build-evidence SHA-256</th><th>Mapped inputs</th></tr></thead><tbody>\n"
            f"{image_rows}\n</tbody></table>\n"
            "<table><thead><tr><th>Source input</th><th>Packaged header</th><th>Bytes</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{notice_rows}\n</tbody></table>\n"
            "<p>Source-header preservation is not a complete runtime license determination or release approval.</p>\n</section>")


def _webgpu_license(project_root: Path) -> Path:
    source = _physical_path_beneath(
        project_root, WEBGPU_LICENSE_SOURCE,
        label="pinned WebGPU BSD-2 license text")
    if sha256_file(source) != WEBGPU_LICENSE_SHA256:
        raise NoticeError("pinned WebGPU BSD-2 license SHA-256 mismatch")
    return source


def _webgpu_adapter_header(project_root: Path) -> Path:
    source = _physical_path_beneath(project_root, WEBGPU_ADAPTER_HEADER_SOURCE,
                                    label="pinned WebGPU Adapter source header")
    if source.stat().st_size != 1336 or sha256_file(source) != WEBGPU_ADAPTER_HEADER_SHA256:
        raise NoticeError("pinned WebGPU Adapter source header hash/size mismatch")
    return source


def _webgpu_image(runtime_frameworks: Path) -> Path:
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("WebKit Frameworks input must be a physical directory")
    image = _physical_path_beneath(
        runtime_frameworks, WEBGPU_IMAGE_PATH,
        label="pinned WebGPU runtime image")
    try:
        build_sha = _runtime_image_build_sha(runtime_frameworks, WEBGPU_IMAGE_PATH,
                                             WEBGPU_IMAGE_SHA256)
    except NoticeError as error:
        raise NoticeError("WebGPU runtime image SHA-256 mismatch") from error
    if build_sha != _current_runtime_hash(WEBGPU_IMAGE_PATH, WEBGPU_IMAGE_SHA256):
        raise NoticeError("WebGPU runtime image SHA-256 mismatch")
    with image.open("rb") as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise NoticeError("WebGPU runtime image is not Mach-O")
    return image


def render_webgpu_markdown(image_sha256: str) -> str:
    if _CURRENT_PRIVATE_V446_QA.get():
        return (f"{WEBGPU_SECTION_MARKER}\n\n"
                "Private Dev QA V446 marker-modified WebGPU image; the original source header "
                "and pinned BSD-2 text are retained. This experimental image is not a release "
                "and its complete notices, build provenance and redistribution status remain unqualified.\n\n"
                f"- Modified build image SHA-256: `{image_sha256}`\n"
                f"- Original Adapter source header SHA-256: `{WEBGPU_ADAPTER_HEADER_SHA256}`\n"
                f"- BSD-2 text SHA-256: `{WEBGPU_LICENSE_SHA256}`\n")
    return (
        f"{WEBGPU_SECTION_MARKER}\n\n"
        "The exact pinned WebKit build image is accompanied by the Apple BSD-2 text below. "
        "The bounded maintainer review maps the 65 compiled WGSL leaf inputs to Apple BSD-2 headers "
        "and the generated declaration inputs to files first added in the pinned WebKit history. "
        "This notice is limited to the exact image hash; it is not legal advice or a determination "
        "for other WebKit images or resources.\n\n"
        f"- Pinned WebKit build image: `{WEBGPU_IMAGE_PATH.as_posix()}`\n"
        f"- Build image SHA-256: `{image_sha256}`\n"
        f"- License text: `NeAntikRuntimeLicenses/{WEBGPU_LICENSE_NAME}`\n"
        f"- License text SHA-256: `{WEBGPU_LICENSE_SHA256}`\n"
        "- Adapter source header: `NeAntikRuntimeLicenses/WebGPU-Adapter-Source-Header.txt` "
        f"(SHA-256 `{WEBGPU_ADAPTER_HEADER_SHA256}`)\n"
        "- Pinned WebKit source revision: `43d5b8d85e2e5eed41d7ff8a79da831bf405be6c`\n"
        "- Source-history evidence: `af938b06692c084c46725628bcdf9a0e0fc96f32`\n"
        "- Policy reference: <https://docs.webkit.org/Other/Licensing.html>\n"
    )


def render_webgpu_html(image_sha256: str) -> str:
    if _CURRENT_PRIVATE_V446_QA.get():
        return (f'{WEBGPU_HTML_MARKER}\n<h2>Private Dev QA V446 WebGPU</h2>\n'
                '<p>This marker-modified image is an experiment; complete notices, build '
                'provenance and redistribution remain unqualified.</p>\n'
                f'<p>Modified build image SHA-256: <code>{image_sha256}</code><br>'
                f'Original Adapter source header SHA-256: <code>{WEBGPU_ADAPTER_HEADER_SHA256}</code><br>'
                f'BSD-2 text SHA-256: <code>{WEBGPU_LICENSE_SHA256}</code></p>\n</section>')
    return (
        f'{WEBGPU_HTML_MARKER}\n<h2>WebGPU build image source notice</h2>\n'
        "<p>The exact pinned WebKit build image is accompanied by the Apple BSD-2 text below. "
        "A bounded maintainer review maps 65 compiled WGSL leaf inputs to Apple BSD-2 headers "
        "and generated declaration inputs to files first added in the pinned WebKit history. "
        "This notice covers this exact image hash only; it is not legal advice or a determination "
        "for other WebKit images or resources.</p>\n"
        f"<ul><li>Pinned WebKit build image: <code>{html.escape(WEBGPU_IMAGE_PATH.as_posix())}</code></li>\n"
        f"<li>Build image SHA-256: <code>{image_sha256}</code></li>\n"
        f"<li>License text: <code>NeAntikRuntimeLicenses/{html.escape(WEBGPU_LICENSE_NAME)}</code></li>\n"
        f"<li>License text SHA-256: <code>{WEBGPU_LICENSE_SHA256}</code></li>\n"
        "<li>Adapter source header: <code>NeAntikRuntimeLicenses/WebGPU-Adapter-Source-Header.txt</code> "
        f"(SHA-256 <code>{WEBGPU_ADAPTER_HEADER_SHA256}</code>)</li>\n"
        "<li>Pinned WebKit source revision: <code>43d5b8d85e2e5eed41d7ff8a79da831bf405be6c</code></li>\n"
        "<li>Source-history evidence: <code>af938b06692c084c46725628bcdf9a0e0fc96f32</code></li>\n"
        "<li>Policy reference: <a href=\"https://docs.webkit.org/Other/Licensing.html\">WebKit Licensing</a></li></ul>\n"
        "</section>"
    )


def render_source_candidate_markdown(manifest: dict) -> str:
    lines = [SOURCE_CANDIDATE_SECTION_MARKER, "",
             "These exact license/copying/patent texts are path-associated candidates from the pinned WebKit source maps. They are included with the app and corresponding-source materials to avoid dropping a discovered text.",
             "Path association is not a decision that every candidate governs the shipped binary; source headers and the corresponding-source offer remain authoritative.", ""]
    for row in manifest["entries"]:
        lines.append(f"- `{row['sourcePath']}` → `NeAntikRuntimeLicenses/WebKitSourceCandidates/{row['outputPath']}`; {row['bytes']} bytes; SHA-256 `{row['sha256']}`.")
    lines.extend(["", "This inventory is not a legal opinion or a claim that source/license review is complete."])
    return "\n".join(lines) + "\n"


def render_source_candidate_html(manifest: dict) -> str:
    rows = "\n".join(
        "<tr><td><code>" + html.escape(row["sourcePath"]) + "</code></td><td><code>" +
        html.escape("NeAntikRuntimeLicenses/WebKitSourceCandidates/" + row["outputPath"]) +
        f"</code></td><td>{row['bytes']}</td><td><code>{row['sha256']}</code></td></tr>"
        for row in manifest["entries"])
    return (f"{SOURCE_CANDIDATE_HTML_MARKER}\n<h2>Pinned WebKit source license-text candidates</h2>\n"
            "<p>These exact texts are associated by source path with the pinned build maps and are included for transparency. That association is not a legal applicability decision.</p>\n"
            "<table><thead><tr><th>Pinned source path</th><th>Packaged text</th><th>Bytes</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{rows}\n</tbody></table>\n"
            "<p>This inventory is not a legal opinion or a claim that source/license review is complete.</p>\n</section>")


def render_sandbox_markdown(rows: tuple[tuple[str, str, str, int], ...]) -> str:
    lines = [SANDBOX_SECTION_MARKER, "",
             "Six exact source files for bundled sandbox resources are copied under "
             "`NeAntikRuntimeLicenses/WebKitSandbox/`. Their copyright and "
             "redistribution conditions are retained in those files.", ""]
    for name, source_path, runtime_path, _size in rows:
        lines.append(f"- `{runtime_path}`: source `{source_path}`; "
                     f"copy `NeAntikRuntimeLicenses/WebKitSandbox/{name}`.")
    lines.extend(["", "This is a source-and-notice byte binding, not a determination "
                  "of every linked image's terms or final redistribution approval."])
    return "\n".join(lines) + "\n"


def render_sandbox_html(rows: tuple[tuple[str, str, str, int], ...]) -> str:
    table = "\n".join(
        "<tr><td><code>" + html.escape(runtime_path) + "</code></td><td><code>" +
        html.escape(source_path) + "</code></td><td><code>" +
        html.escape(f"NeAntikRuntimeLicenses/WebKitSandbox/{name}") + "</code></td></tr>"
        for name, source_path, runtime_path, _size in rows)
    return (f"{SANDBOX_HTML_MARKER}\n"
            "<h2>Bundled WebKit sandbox source notices</h2>\n"
            "<p>Six exact source files for bundled sandbox resources retain "
            "their copyright and redistribution conditions.</p>\n"
            "<table><thead><tr><th>Runtime resource</th><th>Source</th>"
            "<th>Packaged copy</th></tr></thead><tbody>\n"
            f"{table}\n</tbody></table>\n"
            "<p>This source-and-notice binding is not a determination of all "
            "linked-image terms or final redistribution approval.</p>\n</section>")


def _atomic_write(path: Path, data: bytes, *, mode: int | None = None) -> None:
    previous_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    file_mode = previous_mode if mode is None else mode
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), file_mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _compliance_manifest(app: Path, current_html: bytes) -> tuple[Path, dict] | None:
    path = app / "Contents/Resources/NeAntikRuntimeCompliance/compliance-manifest.json"
    if not path.exists() and not path.is_symlink():
        return None
    _physical_file(path, label="Chromium compliance manifest")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("Chromium compliance manifest is unreadable") from error
    notices = value.get("notices") if isinstance(value, dict) else None
    if (not isinstance(value, dict) or value.get("schemaVersion") != 1
            or not isinstance(notices, dict)
            or notices.get("file") != HTML_DESTINATION.name
            or notices.get("sha256") != hashlib.sha256(current_html).hexdigest()):
        raise NoticeError("Chromium compliance manifest does not bind the current notice bytes")
    return path, value


def _refresh_compliance_notice_hash(manifest: tuple[Path, dict] | None, final_html: bytes) -> None:
    if manifest is None:
        return
    path, value = manifest
    value["notices"]["sha256"] = hashlib.sha256(final_html).hexdigest()
    payload = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    _atomic_write(path, payload)


def render_markdown(library_sha256: str) -> str:
    return (
        f"{SECTION_MARKER}\n\n"
        "The bundled owned-WebKit runtime includes `libswiftCompatibilitySpan.dylib`.\n\n"
        f"- Runtime image SHA-256: `{library_sha256}`\n"
        f"- Applicable license text: `NeAntikRuntimeLicenses/{LICENSE_NAME}`\n"
        f"- License SHA-256: `{LICENSE_SHA256}`\n\n"
        "This entry applies only to the named Swift compatibility library. It does not\n"
        "close the separate source, notices, or relinking review for WebKit, WebCore,\n"
        "JavaScriptCore, or other bundled components. Those release gates remain open.\n"
    )


def render_html(library_sha256: str) -> str:
    escaped_name = html.escape(LICENSE_NAME)
    return (
        f'{HTML_MARKER}\n'
        "<h2>Owned WebKit runtime component: CompatibilitySpan</h2>\n"
        "<p>The bundled owned-WebKit runtime includes "
        "<code>libswiftCompatibilitySpan.dylib</code>.</p>\n"
        f"<ul><li>Runtime image SHA-256: <code>{library_sha256}</code></li>\n"
        f"<li>Applicable license text: <code>NeAntikRuntimeLicenses/{escaped_name}</code></li>\n"
        f"<li>License SHA-256: <code>{LICENSE_SHA256}</code></li></ul>\n"
        "<p>This entry applies only to the named Swift compatibility library. "
        "Separate source, notices, and relinking review for WebKit, WebCore, "
        "JavaScriptCore, and other bundled components remains open.</p>\n"
        "</section>"
    )


def render_lgpl2_markdown() -> str:
    return (
        f"{LGPL2_SECTION_MARKER}\n\n"
        "The exact pinned WebCore `LICENSE-LGPL-2` text is included at "
        f"`NeAntikRuntimeLicenses/{WEBCORE_LGPL2_NAME}`.\n\n"
        f"- License text SHA-256: `{WEBCORE_LGPL2_SHA256}`\n\n"
        "This is a source-referenced license-text notice, not a determination "
        "that every WebKit file or shipped binary is governed by these terms. "
        "Per-file scope, corresponding source, relinking, and distribution "
        "requirements remain under review.\n"
    )


def render_lgpl2_html() -> str:
    return (
        f'{LGPL2_HTML_MARKER}\n'
        "<h2>WebKit source-referenced license text: LGPL-2</h2>\n"
        "<p>The exact pinned WebCore <code>LICENSE-LGPL-2</code> text is "
        f"included at <code>NeAntikRuntimeLicenses/{html.escape(WEBCORE_LGPL2_NAME)}</code>.</p>\n"
        f"<p>License text SHA-256: <code>{WEBCORE_LGPL2_SHA256}</code></p>\n"
        "<p>This notice does not determine that every WebKit file or shipped "
        "binary is governed by these terms. Per-file scope, corresponding "
        "source, relinking, and distribution requirements remain under review.</p>\n"
        "</section>"
    )


def render_jsc_copying_lib_markdown() -> str:
    return (
        f"{JSC_COPYING_LIB_SECTION_MARKER}\n\n"
        "The exact `Source/JavaScriptCore/COPYING.LIB` text from the pinned source is included at "
        f"`NeAntikRuntimeLicenses/JavaScriptCore/COPYING.LIB`.\n\n"
        f"- License text SHA-256: `{JSC_COPYING_LIB_SHA256}`\n"
        "- The linked-source header inventory records LGPL-form notices on 59 JavaScriptCore source entries.\n\n"
        "The original source-header bundle is preserved separately. This exact license text and those headers "
        "do not by themselves prove complete corresponding-source delivery or recipient relinking; those gates remain open.\n"
    )


def render_jsc_copying_lib_html() -> str:
    return (
        f'{JSC_COPYING_LIB_HTML_MARKER}\n'
        "<h2>JavaScriptCore source-referenced GNU Library GPL v2 text</h2>\n"
        "<p>The exact <code>Source/JavaScriptCore/COPYING.LIB</code> text from the pinned source is included at "
        "<code>NeAntikRuntimeLicenses/JavaScriptCore/COPYING.LIB</code>.</p>\n"
        f"<p>License text SHA-256: <code>{JSC_COPYING_LIB_SHA256}</code></p>\n"
        "<p>The linked-source header inventory records LGPL-form notices on 59 JavaScriptCore source entries. "
        "The original source-header bundle is preserved separately. Complete corresponding-source delivery "
        "and recipient relinking remain open.</p>\n"
        "</section>"
    )


def render_jsc_binja_markdown() -> str:
    return (
        f"{JSC_BINJA_SECTION_MARKER}\n\n"
        "The pinned WebKit source identifies its ARM64 disassembler as Binary Ninja code under Apache License 2.0. "
        "The exact Vector 35 attribution text and full Apache 2.0 license are included at "
        "`NeAntikRuntimeLicenses/JavaScriptCore/BinaryNinja/`.\n\n"
        f"- Attribution SHA-256: `{JSC_BINJA_ATTRIBUTION_SHA256}`\n"
        f"- Apache License 2.0 SHA-256: `{JSC_BINJA_APACHE_SHA256}`\n\n"
        "The JavaScriptCore image remains under review for other source and terms obligations.\n"
    )


def render_jsc_binja_html() -> str:
    return (
        f'{JSC_BINJA_HTML_MARKER}\n'
        "<h2>JavaScriptCore ARM64 disassembler Binary Ninja Apache-2.0 notices</h2>\n"
        "<p>The pinned WebKit source identifies its ARM64 disassembler as Binary Ninja code under Apache License 2.0. "
        "The exact Vector 35 attribution text and full Apache 2.0 license are included in "
        "<code>NeAntikRuntimeLicenses/JavaScriptCore/BinaryNinja/</code>.</p>\n"
        f"<p>Attribution SHA-256: <code>{JSC_BINJA_ATTRIBUTION_SHA256}</code>; "
        f"Apache license SHA-256: <code>{JSC_BINJA_APACHE_SHA256}</code>.</p>\n"
        "<p>Other JavaScriptCore source and terms obligations remain under review.</p>\n"
        "</section>"
    )


def render_lgpl21_markdown() -> str:
    return (
        f"{LGPL21_SECTION_MARKER}\n\n"
        "The exact pinned WebCore `LICENSE-LGPL-2.1` text is included at "
        f"`NeAntikRuntimeLicenses/{WEBCORE_LGPL21_NAME}`.\n\n"
        f"- License text SHA-256: `{WEBCORE_LGPL21_SHA256}`\n\n"
        "This records source text, not a per-file or per-image license determination. "
        "Applicability, corresponding source, relinking, and distribution remain under review.\n"
    )


def render_lgpl21_html() -> str:
    return (
        f'{LGPL21_HTML_MARKER}\n'
        "<h2>WebKit source-referenced license text: LGPL-2.1</h2>\n"
        "<p>The exact pinned WebCore <code>LICENSE-LGPL-2.1</code> text is "
        f"included at <code>NeAntikRuntimeLicenses/{html.escape(WEBCORE_LGPL21_NAME)}</code>.</p>\n"
        f"<p>License text SHA-256: <code>{WEBCORE_LGPL21_SHA256}</code></p>\n"
        "<p>This records source text, not a per-file or per-image license "
        "determination. Applicability, corresponding source, relinking, and "
        "distribution remain under review.</p>\n</section>"
    )


def render_jsc_tri_license_markdown() -> str:
    return (
        f"{JSC_TRI_LICENSE_SECTION_MARKER}\n\n"
        "The exact pinned JavaScriptCore source file `Source/JavaScriptCore/runtime/JSDateMath.cpp` "
        "contains a source-stated license choice among LGPL-2.1-or-later, MPL-1.1, and GPL-2.0. "
        "Its exact source header is preserved in `NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/JavaScriptCore-SOURCE-HEADERS.txt`; "
        "the pinned source SHA-256 is `4f2ed772401ad09a51707bce46a718f1ec2750a67c3e9a8c566a68a9f30585d4`.\n\n"
        f"- MPL-1.1 text: `NeAntikRuntimeLicenses/JavaScriptCore/MPL-1.1.txt` (SHA-256 `{JSC_MPL11_SHA256}`).\n"
        f"- GPL-2.0 text: `NeAntikRuntimeLicenses/JavaScriptCore/GPL-2.0.txt` (SHA-256 `{JSC_GPL2_SHA256}`).\n"
        f"- LGPL-2.1 text: `NeAntikRuntimeLicenses/{WEBCORE_LGPL21_NAME}` (SHA-256 `{WEBCORE_LGPL21_SHA256}`).\n\n"
        "NeAntik applies the LGPL-2.1 option to its distribution of this file. "
        "The original alternatives remain available to recipients. The separate V8 BSD-style "
        "copyright, binary redistribution conditions, and disclaimer are retained in the source header above. "
        "This file-specific choice does not establish completion of corresponding-source, "
        "relinking, or other runtime-image obligations.\n"
    )


def render_jsc_tri_license_html() -> str:
    return (
        f'{JSC_TRI_LICENSE_HTML_MARKER}\n'
        '<h2>JavaScriptCore JSDateMath.cpp source-stated license alternatives</h2>\n'
        '<p>The exact pinned source file <code>Source/JavaScriptCore/runtime/JSDateMath.cpp</code> '
        'states LGPL-2.1-or-later, MPL-1.1, or GPL-2.0 alternatives. Its exact source header is '
        '<code>NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/JavaScriptCore-SOURCE-HEADERS.txt</code>; '
        'source SHA-256: <code>4f2ed772401ad09a51707bce46a718f1ec2750a67c3e9a8c566a68a9f30585d4</code>.</p>\n'
        f'<ul><li>MPL-1.1: <code>NeAntikRuntimeLicenses/JavaScriptCore/MPL-1.1.txt</code> '
        f'(SHA-256 <code>{JSC_MPL11_SHA256}</code>)</li>'
        f'<li>GPL-2.0: <code>NeAntikRuntimeLicenses/JavaScriptCore/GPL-2.0.txt</code> '
        f'(SHA-256 <code>{JSC_GPL2_SHA256}</code>)</li>'
        f'<li>LGPL-2.1: <code>NeAntikRuntimeLicenses/{html.escape(WEBCORE_LGPL21_NAME)}</code> '
        f'(SHA-256 <code>{WEBCORE_LGPL21_SHA256}</code>)</li></ul>\n'
        '<p>NeAntik applies the LGPL-2.1 option to its distribution of this file. '
        'The original alternatives remain available to recipients. The separate V8 BSD-style '
        'copyright, binary redistribution conditions, and disclaimer are retained in the source header above. '
        'This file-specific choice does not close corresponding-source, relinking, or other runtime-image obligations.</p>\n'
        '</section>'
    )


def render_angle_markdown(library_sha256: str) -> str:
    return (
        f"{ANGLE_SECTION_MARKER}\n\n"
        "The bundled owned-WebKit runtime includes `libANGLE-shared.dylib`. "
        "The exact candidate image retains xxHash and ANGLE zlib compression helper symbols.\n\n"
        f"- Runtime image SHA-256: `{library_sha256}`\n"
        f"- ANGLE license: `NeAntikRuntimeLicenses/{ANGLE_LICENSE_NAME}` "
        f"(SHA-256 `{ANGLE_LICENSE_SHA256}`)\n"
        f"- xxHash license: `NeAntikRuntimeLicenses/{XXHASH_LICENSE_NAME}` "
        f"(SHA-256 `{XXHASH_LICENSE_SHA256}`)\n"
        f"- Chromium DEPS license: `NeAntikRuntimeLicenses/{CHROMIUM_ANGLE_LICENSE_NAME}` "
        f"(SHA-256 `{CHROMIUM_ANGLE_LICENSE_SHA256}`)\n\n"
        "These notices follow the pinned CMake/link map and retained image symbols. "
        "They do not establish complete notice coverage for every image/resource "
        "or provide a legal conclusion.\n"
    )


def render_angle_html(library_sha256: str) -> str:
    return (
        f'{ANGLE_HTML_MARKER}\n'
        "<h2>Source-mapped WebKit runtime notices: ANGLE</h2>\n"
        "<p>The bundled owned-WebKit runtime includes "
        "<code>libANGLE-shared.dylib</code>. The exact candidate image retains "
        "xxHash and ANGLE zlib compression helper symbols.</p>\n"
        f"<ul><li>Runtime image SHA-256: <code>{library_sha256}</code></li>\n"
        f"<li>ANGLE license: <code>NeAntikRuntimeLicenses/{html.escape(ANGLE_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{ANGLE_LICENSE_SHA256}</code>)</li>\n"
        f"<li>xxHash license: <code>NeAntikRuntimeLicenses/{html.escape(XXHASH_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{XXHASH_LICENSE_SHA256}</code>)</li>\n"
        f"<li>Chromium DEPS license: <code>NeAntikRuntimeLicenses/{html.escape(CHROMIUM_ANGLE_LICENSE_NAME)}</code> "
        f"(SHA-256 <code>{CHROMIUM_ANGLE_LICENSE_SHA256}</code>)</li></ul>\n"
        "<p>These notices follow the pinned CMake/link map and retained image "
        "symbols. Completeness for all images/resources and legal applicability "
        "remain under review.</p>\n</section>"
    )


def render_webrtc_markdown(library_sha256: str, manifest: dict,
                           notices: tuple[tuple[Path, Path, str, int], ...]) -> str:
    lines = [
        f"{WEBRTC_SECTION_MARKER}", "",
        "This source-derived candidate covers the pinned CMake `libwebrtc.dylib` link/source receipts only.", "",
        f"- Pre-signing build-stage image SHA-256: `{library_sha256}`",
        f"- WebKit source archive recorded by the notice manifest SHA-256: `{manifest['upstream']['sha256']}`",
        f"- Candidate manifest: `NeAntikRuntimeLicenses/WebRTC/MANIFEST.json` "
        f"(SHA-256 `{WEBRTC_MANIFEST_SHA256}`)",
        f"- Source notice files: {len(notices)}", "",
        "The exact libwebm authors list is included separately at "
        "`NeAntikRuntimeLicenses/WebRTC/supplements/libwebm/AUTHORS.TXT` "
        f"(SHA-256 `{WEBRTC_LIBWEBM_AUTHORS_SHA256}`); it supplements the unchanged candidate manifest.", "",
        "The rnnoise source header is included at `NeAntikRuntimeLicenses/WebRTC/supplements/rnnoise/rnn-activations-header.txt` "
        f"(SHA-256 `{RNNOISE_HEADER_SHA256}`).", "",
        "Additional libsrtp source headers are at `NeAntikRuntimeLicenses/WebRTC/supplements/libsrtp/source-headers.txt` "
        f"(SHA-256 `{LIBSRTP_HEADERS_SHA256}`).", "",
        "Additional Opus source headers are at `NeAntikRuntimeLicenses/WebRTC/supplements/opus/source-headers.txt` "
        f"(SHA-256 `{OPUS_HEADERS_SHA256}`).", "",
        "Additional libaom source-header notices for `aom_ext_ratectrl.h`, `aom_external_partition.h`, "
        "and `aom_tpl.h` are included under `NeAntikRuntimeLicenses/WebRTC/supplements/libaom-header-notices/`. "
        "They preserve the exact 2021 and 2025 Alliance for Open Media copyright and BSD 2 Clause / "
        "Alliance for Open Media Patent License notices.", "",
        "The NeAntik-owned `Source/ThirdParty/libwebrtc/cmake/usage_exit_stub.c` "
        "declares `MPL-2.0` (Copyright (c) 2026 NeAntik contributors). "
        "Its license text is `NeAntikRuntimeLicenses/WebRTC/NeAntik-usage_exit_stub-MPL-2.0.txt` "
        f"(SHA-256 `{WEBRTC_MPL2_SHA256}`). The matching source file is in the pinned WebKit source/patch offer.", "",
        "The source-derived mapping is not a complete runtime notice bundle, legal opinion, or redistribution approval. "
        "WebCore/PAL/ANGLE/resources, source and relinking duties, and qualified review remain separate release gates.", "",
        "| Pinned source path | SHA-256 |", "| --- | --- |",
    ]
    lines.extend(f"| `{source}` | `{digest}` |" for source, _output, digest, _size in notices)
    return "\n".join(lines) + "\n"


def render_webrtc_html(library_sha256: str, manifest: dict,
                       notices: tuple[tuple[Path, Path, str, int], ...]) -> str:
    rows = "\n".join(
        f"<tr><td><code>{html.escape(source.as_posix())}</code></td>"
        f"<td><code>{digest}</code></td></tr>"
        for source, _output, digest, _size in notices
    )
    return (
        f'{WEBRTC_HTML_MARKER}\n<h2>Source-derived WebRTC notices: CMake libwebrtc.dylib</h2>\n'
        "<p>This source-derived candidate covers the pinned CMake link/source receipts only.</p>\n"
        f"<p>Pre-signing build-stage image SHA-256: <code>{library_sha256}</code><br>"
        f"WebKit source archive recorded by the notice manifest SHA-256: <code>{html.escape(manifest['upstream']['sha256'])}</code><br>"
        f"Candidate manifest: <code>NeAntikRuntimeLicenses/WebRTC/MANIFEST.json</code> "
        f"(SHA-256 <code>{WEBRTC_MANIFEST_SHA256}</code>)<br>Source notice files: {len(notices)}</p>\n"
        '<p>The exact libwebm authors list is included separately at '
        '<code>NeAntikRuntimeLicenses/WebRTC/supplements/libwebm/AUTHORS.TXT</code> '
        f'(SHA-256 <code>{WEBRTC_LIBWEBM_AUTHORS_SHA256}</code>); it supplements the unchanged candidate manifest.</p>\n'
        '<p>The rnnoise source header is included at <code>NeAntikRuntimeLicenses/WebRTC/supplements/rnnoise/rnn-activations-header.txt</code> '
        f'(SHA-256 <code>{RNNOISE_HEADER_SHA256}</code>).</p>\n'
        '<p>Additional libsrtp source headers: <code>NeAntikRuntimeLicenses/WebRTC/supplements/libsrtp/source-headers.txt</code> '
        f'(SHA-256 <code>{LIBSRTP_HEADERS_SHA256}</code>).</p>\n'
        '<p>Additional Opus source headers: <code>NeAntikRuntimeLicenses/WebRTC/supplements/opus/source-headers.txt</code> '
        f'(SHA-256 <code>{OPUS_HEADERS_SHA256}</code>).</p>\n'
        '<p>Additional libaom source-header notices for <code>aom_ext_ratectrl.h</code>, '
        '<code>aom_external_partition.h</code>, and <code>aom_tpl.h</code> are included under '
        '<code>NeAntikRuntimeLicenses/WebRTC/supplements/libaom-header-notices/</code>. '
        'They preserve the exact 2021 and 2025 Alliance for Open Media copyright and BSD 2 Clause / '
        'Alliance for Open Media Patent License notices.</p>\n'
        "<p>The NeAntik-owned <code>Source/ThirdParty/libwebrtc/cmake/usage_exit_stub.c</code> "
        "declares MPL-2.0 (Copyright (c) 2026 NeAntik contributors). "
        "License text: <code>NeAntikRuntimeLicenses/WebRTC/NeAntik-usage_exit_stub-MPL-2.0.txt</code> "
        f"(SHA-256 <code>{WEBRTC_MPL2_SHA256}</code>). The matching source file is in the pinned WebKit source/patch offer.</p>\n"
        "<p>This is not a complete runtime notice bundle, legal opinion, or redistribution approval. "
        "Other runtime images/resources, source and relinking duties, and qualified review remain open.</p>\n"
        f"<table><thead><tr><th>Pinned source path</th><th>SHA-256</th></tr></thead>"
        f"<tbody>{rows}</tbody></table>\n</section>"
    )


def render_linked_headers_markdown(manifest: dict) -> str:
    lines = [LINKED_HEADERS_SECTION_MARKER, "",
             "The exact source-file headers below are preserved for the pinned v20 JavaScriptCore, WebCore/PAL and WebKit link inputs. Generated output terms, conditional inclusion, other linked components and recipient replacement remain separate release gates.", "",
             f"- Manifest: `NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/MANIFEST.json` (SHA-256 `{LINKED_HEADERS_MANIFEST_SHA256}`)."]
    for row in manifest["images"]:
        lines.append(
            f"- `{row['runtimePath']}` (build-evidence SHA-256 `{_current_runtime_hash(row['runtimePath'], row['runtimeSHA256'])}`): "
            f"{row['noticeEntryCount']} source headers at "
            f"`NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/{row['noticePath']}` "
            f"(SHA-256 `{row['noticeSHA256']}`).")
    lines.append(f"- Additional dav1d source headers: `NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/dav1d-source-header-supplement.txt` (SHA-256 `{DAV1D_HEADERS_SHA256}`).")
    return "\n".join(lines) + "\n"


def render_linked_headers_html(manifest: dict) -> str:
    rows = "\n".join(
        f"<tr><td><code>{html.escape(row['runtimePath'])}</code></td>"
        f"<td>{row['noticeEntryCount']}</td>"
        f"<td><code>NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/{html.escape(row['noticePath'])}</code></td>"
        f"<td><code>{row['noticeSHA256']}</code></td></tr>"
        for row in manifest["images"])
    return (f'{LINKED_HEADERS_HTML_MARKER}\n<h2>Exact linked JavaScriptCore, WebCore and WebKit source headers</h2>\n'
            "<p>These pinned source-file headers are preserved for the v20 link inputs. Generated output terms, conditional inclusion, other linked components and recipient replacement remain separate release gates.</p>\n"
            f"<p>Manifest SHA-256: <code>{LINKED_HEADERS_MANIFEST_SHA256}</code></p>\n"
            f"<p>Additional dav1d source headers: <code>NeAntikRuntimeLicenses/WebKitLinkedSourceHeaders/dav1d-source-header-supplement.txt</code> (SHA-256 <code>{DAV1D_HEADERS_SHA256}</code>).</p>\n"
            "<table><thead><tr><th>Runtime image</th><th>Headers</th><th>Packaged notice</th><th>SHA-256</th></tr></thead><tbody>\n"
            f"{rows}\n</tbody></table>\n</section>")


def render_webcore_generated_headers_markdown() -> str:
    return (f"{WEBCORE_GENERATED_HEADERS_SECTION_MARKER}\n\n"
            "The pinned v20 WebCore generator inputs for 12 linked generated implementations "
            "include 29 explicit source-header signals among 36 physical inputs. "
            "The same hash-bound bundle also preserves the exact LGPL-2-or-later headers from the three linked generated Touch outputs. "
            "The matching WebCore LGPL-2 text is included separately. This bounded notice does not close full-image license applicability or recipient replacement.\n\n"
            "- `NeAntikRuntimeLicenses/WebCoreGeneratedInputHeaders.txt` "
            f"(SHA-256 `{WEBCORE_GENERATED_HEADERS_SHA256}`).\n")


def render_webcore_generated_headers_html() -> str:
    return (f'{WEBCORE_GENERATED_HEADERS_HTML_MARKER}\n'
            '<h2>WebCore generated-input source headers</h2>\n'
            '<p>Exact v20 inputs for 12 linked generated implementations: 29 explicit header signals '
            'among 36 physical inputs. The same hash-bound bundle preserves the exact LGPL-2-or-later headers '
            'from three linked generated Touch outputs; the matching WebCore LGPL-2 text is included separately. '
            'Full-image license applicability and recipient replacement remain open.</p>\n'
            '<p>Packaged evidence: <code>NeAntikRuntimeLicenses/WebCoreGeneratedInputHeaders.txt</code>; '
            f'SHA-256 <code>{WEBCORE_GENERATED_HEADERS_SHA256}</code>.</p>\n</section>')


def render_webcore_popover_markdown(review_sha256: str) -> str:
    return (f"{WEBCORE_POPOVER_SECTION_MARKER}\n\n"
            "The exact v20 WebCore input `Source/WebCore/css/popover.css` was introduced as a new file by "
            "Tim Nguyen on 2023-02-11. WebKit's licensing policy assigns new WebKit contributions to BSD-2-Clause; "
            "the maintainer uses the individual-author attribution `Copyright (C) 2023 Tim Nguyen.` in the pinned notice. This is a scoped "
            "input notice, not a legal opinion or a WebCore image license conclusion.\n\n"
            f"- Source SHA-256: `0c46fec1026f3c6b9b2fa90724cf12c39b3a8628857a30675f39e4f14f6a62a6`.\n"
            f"- Build-stage source-input SHA-256: `{_current_runtime_hash('WebCore.framework/Versions/A/WebCore', WEBCORE_POPOVER_RUNTIME_SHA256)}`.\n"
            f"- BSD-2 text: `NeAntikRuntimeLicenses/WebCore/PopoverCSS-BSD-2-Clause.txt` "
            f"(SHA-256 `{WEBCORE_POPOVER_LICENSE_SHA256}`).\n"
            f"- Source review: `NeAntikRuntimeLicenses/WebCore/PopoverCSSReview.json` "
            f"(SHA-256 `{review_sha256}`).\n\n"
            "Other WebCore inputs/resources, complete image applicability, corresponding source, and recipient relinking remain open.\n")


def render_webcore_popover_html(review_sha256: str) -> str:
    return (f'{WEBCORE_POPOVER_HTML_MARKER}\n<h2>WebCore popover.css source notice</h2>\n'
            '<p>The exact v20 input <code>Source/WebCore/css/popover.css</code> was introduced as a new file by '
            'Tim Nguyen on 2023-02-11. WebKit policy assigns new contributions to BSD-2-Clause; the maintainer '
            'uses the individual-author line <code>Copyright (C) 2023 Tim Nguyen.</code>. This scoped input notice is not a legal opinion or a WebCore image license conclusion.</p>\n'
            '<ul><li>Source SHA-256: <code>0c46fec1026f3c6b9b2fa90724cf12c39b3a8628857a30675f39e4f14f6a62a6</code></li>'
            f'<li>Build-stage source-input SHA-256: <code>{_current_runtime_hash("WebCore.framework/Versions/A/WebCore", WEBCORE_POPOVER_RUNTIME_SHA256)}</code></li>'
            f'<li>BSD-2 text: <code>NeAntikRuntimeLicenses/WebCore/PopoverCSS-BSD-2-Clause.txt</code> '
            f'(SHA-256 <code>{WEBCORE_POPOVER_LICENSE_SHA256}</code>)</li>'
            f'<li>Source review: <code>NeAntikRuntimeLicenses/WebCore/PopoverCSSReview.json</code> '
            f'(SHA-256 <code>{review_sha256}</code>)</li></ul>\n'
            '<p>Other WebCore inputs/resources, complete image applicability, corresponding source, and recipient relinking remain open.</p>\n</section>')


def render_webcore_colordata_markdown(review_sha256: str) -> str:
    return (f"{WEBCORE_COLORDATA_SECTION_MARKER}\n\n"
            "The exact v20 WebCore input `Source/WebCore/platform/ColorData.gperf` descends from a new WebKit file "
            "`WebCore/kwq/KWQColorData.gperf`, added by Darin Adler on 2002-12-15. The hash-bound lineage review "
            "and WebKit new-code licensing policy support a maintainer BSD-2 classification and individual-author "
            "attribution. This is not a legal opinion or a WebCore image license conclusion.\n\n"
            f"- Source SHA-256: `dc1f82bbdc6090f232b5aabd9a86eacb44df1dd23e6f68f4e08e0b378ee8836d`.\n"
            f"- Build-stage source-input SHA-256: `{_current_runtime_hash('WebCore.framework/Versions/A/WebCore', WEBCORE_POPOVER_RUNTIME_SHA256)}`.\n"
            f"- BSD-2 text: `NeAntikRuntimeLicenses/WebCore/ColorData-BSD-2-Clause.txt` "
            f"(SHA-256 `{WEBCORE_COLORDATA_LICENSE_SHA256}`; Copyright (C) 2002 Darin Adler.).\n"
            f"- Source review: `NeAntikRuntimeLicenses/WebCore/ColorDataReview.json` "
            f"(SHA-256 `{review_sha256}`).\n\n"
            "Other WebCore inputs/resources, full image terms, corresponding source, and recipient relinking remain open.\n")


def render_webcore_colordata_html(review_sha256: str) -> str:
    return (f'{WEBCORE_COLORDATA_HTML_MARKER}\n<h2>WebCore ColorData.gperf source notice</h2>\n'
            '<p>The exact v20 input <code>Source/WebCore/platform/ColorData.gperf</code> descends from a new WebKit file '
            '<code>WebCore/kwq/KWQColorData.gperf</code>, added by Darin Adler on 2002-12-15. The hash-bound lineage review '
            'and WebKit policy support the maintainer BSD-2 classification and individual-author attribution. This is not a legal opinion or a WebCore image license conclusion.</p>\n'
            '<ul><li>Source SHA-256: <code>dc1f82bbdc6090f232b5aabd9a86eacb44df1dd23e6f68f4e08e0b378ee8836d</code></li>'
            f'<li>Build-stage source-input SHA-256: <code>{_current_runtime_hash("WebCore.framework/Versions/A/WebCore", WEBCORE_POPOVER_RUNTIME_SHA256)}</code></li>'
            f'<li>BSD-2 text: <code>NeAntikRuntimeLicenses/WebCore/ColorData-BSD-2-Clause.txt</code> '
            f'(SHA-256 <code>{WEBCORE_COLORDATA_LICENSE_SHA256}</code>; Copyright (C) 2002 Darin Adler.)</li>'
            f'<li>Source review: <code>NeAntikRuntimeLicenses/WebCore/ColorDataReview.json</code> '
            f'(SHA-256 <code>{review_sha256}</code>)</li></ul>\n'
            '<p>Other WebCore inputs/resources, full image terms, corresponding source, and recipient relinking remain open.</p>\n</section>')


def render_webcore_css_generated_markdown(review_sha256: str) -> str:
    return (f"{WEBCORE_CSS_GENERATED_SECTION_MARKER}\n\n"
            "This notice covers three exact WebCore generated CSS inputs: `CSSProperties.json`, "
            "`CSSValueKeywords.in`, and `SVGCSSValueKeywords.in`. Their pinned source files and "
            "historical predecessors contain no file-level copyright header. The source review "
            "classifies BSD-2 terms for WebCore-native contributions and LGPL terms for mapped "
            "KHTML/KSVG2 portions, and preserves the upstream project-level license texts. It "
            "does not infer a unique per-file rights holder or prove rights assignment.\n\n"
            f"- WebCore build-stage source-input SHA-256: `{_current_runtime_hash('WebCore.framework/Versions/A/WebCore', WEBCORE_POPOVER_RUNTIME_SHA256)}`.\n"
            f"- Apple BSD-2 license: `NeAntikRuntimeLicenses/WebCore/WebCore-LICENSE-APPLE.txt` "
            f"(SHA-256 `{WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256}`).\n"
            f"- LGPL-2 text retained for mapped legacy portions: `NeAntikRuntimeLicenses/WebCore/LGPL-2.txt` "
            f"(SHA-256 `{WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256}`).\n"
            f"- Source lineage and term review: `NeAntikRuntimeLicenses/WebCore/CSSGeneratedInputsReview.json` "
            f"(SHA-256 `{review_sha256}`).\n\n"
            "Per-file rights-holder attribution, complete WebCore image terms, corresponding source, and recipient relinking remain open.\n")


def render_webcore_css_generated_html(review_sha256: str) -> str:
    return (f'{WEBCORE_CSS_GENERATED_HTML_MARKER}\n<h2>WebCore generated CSS input notices</h2>\n'
            '<p>This notice covers the exact `CSSProperties.json`, `CSSValueKeywords.in`, and '
            '`SVGCSSValueKeywords.in` inputs. Their pinned source files and historical predecessors '
            'contain no file-level copyright header. The review classifies BSD-2 terms for WebCore-native '
            'contributions and LGPL terms for mapped KHTML/KSVG2 portions, and preserves upstream '
            'project-level license texts. It does not infer a unique per-file rights holder or prove rights assignment.</p>\n'
            f'<ul><li>WebCore build-stage source-input SHA-256: <code>{_current_runtime_hash("WebCore.framework/Versions/A/WebCore", WEBCORE_POPOVER_RUNTIME_SHA256)}</code></li>'
            f'<li>Apple BSD-2 text: <code>NeAntikRuntimeLicenses/WebCore/WebCore-LICENSE-APPLE.txt</code> '
            f'(SHA-256 <code>{WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256}</code>)</li>'
            f'<li>LGPL-2 text: <code>NeAntikRuntimeLicenses/WebCore/LGPL-2.txt</code> '
            f'(SHA-256 <code>{WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256}</code>)</li>'
            f'<li>Source review: <code>NeAntikRuntimeLicenses/WebCore/CSSGeneratedInputsReview.json</code> '
            f'(SHA-256 <code>{review_sha256}</code>)</li></ul>\n'
            '<p>Per-file rights-holder attribution, complete WebCore image terms, corresponding source, and recipient relinking remain open.</p>\n</section>')


def _webcore_media_controls_overlay(project_root: Path, runtime_frameworks: Path | None,
                                    source_offer_root: Path | None) -> dict[str, object] | None:
    """Bind the first-party art license only when the exact overlay bytes ship."""
    if source_offer_root is None:
        return None
    if runtime_frameworks is None:
        raise NoticeError("first-party media-controls notice requires exact runtime framework bytes")
    overlay = source_offer_root / WEBCORE_MEDIA_CONTROLS_OVERLAY_RELATIVE
    if overlay.is_symlink() or not overlay.is_dir():
        raise NoticeError("pinned first-party media-controls source-offer overlay is unavailable")
    try:
        overlay.resolve(strict=True).relative_to(source_offer_root.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise NoticeError("media-controls overlay escapes the pinned source offer") from error
    attribution_path = _physical_path_beneath(
        overlay, Path("ATTRIBUTION.json"), label="media-controls overlay attribution")
    license_path = _physical_path_beneath(
        overlay, Path("LICENSE.txt"), label="media-controls BSD-2 license")
    try:
        attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("media-controls overlay attribution is invalid JSON") from error
    assets = attribution.get("assets")
    if (attribution.get("schemaVersion") != 1 or attribution.get("license") != "BSD-2-Clause"
            or attribution.get("assetCount") != 35 or not isinstance(assets, list)
            or len(assets) != 35):
        raise NoticeError("media-controls overlay license or attribution scope mismatch")
    expected_runtime: dict[str, str] = {}
    for row in assets:
        if (not isinstance(row, dict) or row.get("license") != "BSD-2-Clause"
                or not isinstance(row.get("path"), str)
                or not row["path"].startswith(
                    "Source/WebCore/Modules/modern-media-controls/images/macOS/")
                or not re.fullmatch(r"[0-9a-f]{64}", str(row.get("sha256", "")))):
            raise NoticeError("media-controls overlay asset attribution row is invalid")
        relative = Path(row["path"]).relative_to("Source/WebCore/Modules/modern-media-controls/images/macOS")
        runtime_relative = (Path("WebCore.framework/Versions/A/Resources/modern-media-controls/images")
                            / relative)
        expected_runtime[runtime_relative.as_posix()] = row["sha256"]
        replacement = _physical_path_beneath(overlay, Path("Source") / Path(row["path"]).relative_to("Source"),
                                             label="media-controls replacement asset")
        if replacement.stat().st_size != row.get("bytes") or sha256_file(replacement) != row["sha256"]:
            raise NoticeError("media-controls replacement asset differs from attribution")
    if len(expected_runtime) != 35:
        raise NoticeError("media-controls overlay contains duplicate asset paths")
    if runtime_frameworks is not None:
        for relative, expected in expected_runtime.items():
            runtime = _physical_path_beneath(runtime_frameworks, Path(relative),
                                             label="WebCore replacement media-controls resource")
            if sha256_file(runtime) != expected:
                raise NoticeError(f"WebCore media-controls runtime does not match first-party overlay: {relative}")
    return {"overlay": overlay, "attribution": attribution_path, "license": license_path,
            "attributionSHA256": sha256_file(attribution_path),
            "licenseSHA256": sha256_file(license_path), "runtimeAssets": expected_runtime}


def _webcore_first_party_resource_overlays(
    runtime_frameworks: Path | None, source_offer_root: Path | None,
) -> list[dict[str, object]] | None:
    """Bind exact first-party WebCore replacements to runtime bytes and package notices."""
    if source_offer_root is None:
        return None
    if runtime_frameworks is None:
        raise NoticeError("first-party WebCore resource notices require exact runtime framework bytes")
    specs = (
        ("neantik-core-ui-original-v1", 7, "42d7a46b8ac2d76bb5f6008dc689d0d34a8598f80987623e9c1eb421a3b7b4a8"),
        ("neantik-original-cursors-v1", 8, "b356f3ed6c8346aade670cbb991e8196974baf2563866e22a452b70e18ae2d73"),
        ("neantik-delete-button-first-party-v1", 1, "077042f44b6e17f7c70d13d59241528a20f952a47688149f310bf46ac8f22c81"),
        ("neantik-linear-srgb-icc-v1", 1, "406fab52fca09ecf6fc4bc168a7ae16814b6e69d4b3dc689cdbe0b2aaa4737dd"),
        ("neantik-first-party-webcore-contentfilter-v1", 1, "377c48c73dc16070915c9488922c6725a4d28a1d478ee8d7934c017fe48a46a7"),
    )
    offer = source_offer_root.resolve(strict=True)
    try:
        manifest = json.loads((offer / "manifest.json").read_text(encoding="utf-8"))
        components = manifest["sourceOfferComponents"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise NoticeError("WebCore first-party source-offer manifest is invalid") from error
    component_map = {row.get("path"): row for row in components if isinstance(row, dict)}
    if len(component_map) != len(components):
        raise NoticeError("WebCore first-party source-offer manifest contains duplicate component paths")
    result: list[dict[str, object]] = []
    all_runtime_paths: set[str] = set()
    for name, expected_count, expected_attribution_hash in specs:
        overlay = offer / "overlays" / name
        if overlay.is_symlink() or not overlay.is_dir():
            raise NoticeError(f"first-party WebCore source-offer overlay is unavailable: {name}")
        try:
            overlay.resolve(strict=True).relative_to(offer)
        except (OSError, ValueError) as error:
            raise NoticeError(f"first-party WebCore overlay escapes source offer: {name}") from error
        attribution_path = _physical_path_beneath(overlay, Path("ATTRIBUTION.json"),
                                                   label=f"{name} attribution")
        license_path = _physical_path_beneath(overlay, Path("LICENSE.txt"),
                                               label=f"{name} license")
        try:
            attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise NoticeError(f"first-party WebCore attribution is invalid: {name}") from error
        assets = attribution.get("assets")
        if (sha256_file(attribution_path) != expected_attribution_hash
                or sha256_file(license_path) != "3ab0de831861966f2c2ec76d3ba1b24473c64ee08cb7699327a2005fca688ff7"
                or attribution.get("schemaVersion") != 1
                or attribution.get("license") not in (None, "BSD-2-Clause")
                or not isinstance(assets, list)
                or len(assets) != expected_count or attribution.get("assetCount") != expected_count):
            raise NoticeError(f"first-party WebCore attribution scope mismatch: {name}")
        component_paths = [f"overlays/{name}/ATTRIBUTION.json", f"overlays/{name}/LICENSE.txt"]
        for relative in component_paths:
            record = component_map.get(relative)
            path = offer / relative
            if (record is None or record.get("includedInOfferFolder") is not True
                    or record.get("bytes") != path.stat().st_size
                    or record.get("sha256") != sha256_file(path)):
                raise NoticeError(f"WebCore overlay notice is not bound by source-offer manifest: {relative}")
        expected_runtime: dict[str, str] = {}
        for row in assets:
            source_path = row.get("path") if isinstance(row, dict) else None
            if (not isinstance(source_path, str) or not source_path.startswith("Source/WebCore/Resources/")
                    or row.get("license") != "BSD-2-Clause"
                    or not isinstance(row.get("copyright"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", str(row.get("sha256", "")))
                    or not isinstance(row.get("bytes"), int)):
                raise NoticeError(f"WebCore first-party asset attribution row is invalid: {name}")
            relative_source = Path(source_path)
            if relative_source.is_absolute() or ".." in relative_source.parts:
                raise NoticeError(f"WebCore replacement source path is unsafe: {source_path}")
            replacement = _physical_path_beneath(overlay, relative_source,
                                                 label=f"{name} replacement asset")
            digest = row["sha256"]
            if replacement.stat().st_size != row["bytes"] or sha256_file(replacement) != digest:
                raise NoticeError(f"WebCore replacement asset differs from attribution: {source_path}")
            relative_runtime = Path("WebCore.framework/Versions/A/Resources") / relative_source.name
            if relative_runtime.as_posix() in expected_runtime or relative_runtime.as_posix() in all_runtime_paths:
                raise NoticeError(f"duplicate WebCore runtime resource path: {relative_runtime}")
            runtime = _physical_path_beneath(runtime_frameworks, relative_runtime,
                                             label=f"{name} runtime resource")
            if sha256_file(runtime) != digest:
                raise NoticeError(f"WebCore runtime resource differs from first-party overlay: {relative_runtime}")
            expected_runtime[relative_runtime.as_posix()] = digest
            all_runtime_paths.add(relative_runtime.as_posix())
            asset_component = f"overlays/{name}/{source_path}"
            record = component_map.get(asset_component)
            if (record is None or record.get("includedInOfferFolder") is not True
                    or record.get("bytes") != replacement.stat().st_size
                    or record.get("sha256") != digest):
                raise NoticeError(f"WebCore replacement asset is not bound by source-offer manifest: {source_path}")
        result.append({"name": name, "overlay": overlay, "attribution": attribution_path,
                       "license": license_path, "attributionSHA256": sha256_file(attribution_path),
                       "licenseSHA256": sha256_file(license_path), "runtimeAssets": expected_runtime})
    return result


WEBCORE_FIRST_PARTY_SECTION_MARKER = "## WebCore first-party replacement resource notices"
WEBCORE_FIRST_PARTY_HTML_MARKER = '<section id="neantik-webcore-first-party-replacement-notices">'
WEBCORE_FIRST_PARTY_NOTICE_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebCore/FirstParty")


def render_webcore_first_party_markdown(overlays: list[dict[str, object]] | None) -> str:
    if not overlays:
        return ""
    lines = [WEBCORE_FIRST_PARTY_SECTION_MARKER, "",
             "These exact WebCore runtime resources are first-party replacements; BSD-2-Clause and attribution apply only to the listed replacement bytes.", ""]
    for row in overlays:
        name = str(row["name"])
        count = len(row["runtimeAssets"])
        prefix = f"NeAntikRuntimeLicenses/WebCore/FirstParty/{name}"
        lines.extend((f"### `{name}` ({count} runtime resource(s))", "",
                      f"- License: `{prefix}/LICENSE.txt` (SHA-256 `{row['licenseSHA256']}`).",
                      f"- Attribution: `{prefix}/ATTRIBUTION.json` (SHA-256 `{row['attributionSHA256']}`).", ""))
    return "\n".join(lines)


def render_webcore_first_party_html(overlays: list[dict[str, object]] | None) -> str:
    if not overlays:
        return ""
    parts = [WEBCORE_FIRST_PARTY_HTML_MARKER,
             "<h2>WebCore first-party replacement resource notices</h2>",
             "<p>BSD-2-Clause applies only to these exact first-party replacement bytes.</p>"]
    for row in overlays:
        name = str(row["name"])
        prefix = f"NeAntikRuntimeLicenses/WebCore/FirstParty/{name}"
        parts.append(f'<h3>{name} ({len(row["runtimeAssets"])} runtime resource(s))</h3><ul>'
                     f'<li>License: <code>{prefix}/LICENSE.txt</code> (SHA-256 <code>{row["licenseSHA256"]}</code>)</li>'
                     f'<li>Attribution: <code>{prefix}/ATTRIBUTION.json</code> (SHA-256 <code>{row["attributionSHA256"]}</code>)</li></ul>')
    parts.append("</section>")
    return "\n".join(parts)


WEBKIT_WARNING_COLOR_SECTION_MARKER = "## WebKit first-party warning color resources"
WEBKIT_WARNING_COLOR_HTML_MARKER = '<section id="neantik-webkit-warning-colors-notices">'
WEBKIT_WARNING_COLOR_NOTICE_ROOT = Path(
    "Contents/Resources/NeAntikRuntimeLicenses/WebKit/FirstParty")


def render_webkit_warning_color_markdown(binding: dict[str, object] | None) -> str:
    if binding is None:
        return ""
    name = str(binding["name"])
    prefix = f"NeAntikRuntimeLicenses/WebKit/FirstParty/{name}"
    return (f"{WEBKIT_WARNING_COLOR_SECTION_MARKER}\n\n"
            "The 9 source catalog files are first-party BSD-2-Clause replacements. Their compiled color values were matched to the exact WebKit Assets.car bytes by asset name and light/dark appearance.\n\n"
            f"- Compiled resource: `{binding['runtimePath']}` (SHA-256 `{binding['runtimeSHA256']}`); verified color sets: `{binding['colorCount']}`.\n"
            f"- License: `{prefix}/LICENSE.txt` (SHA-256 `{binding['licenseSHA256']}`).\n"
            f"- Attribution: `{prefix}/ATTRIBUTION.json` (SHA-256 `{binding['attributionSHA256']}`).\n")


def render_webkit_warning_color_html(binding: dict[str, object] | None) -> str:
    if binding is None:
        return ""
    name = str(binding["name"])
    prefix = f"NeAntikRuntimeLicenses/WebKit/FirstParty/{name}"
    return (f"{WEBKIT_WARNING_COLOR_HTML_MARKER}\n<h2>WebKit first-party warning colors</h2>\n"
            f"<p>Nine source catalog files are first-party BSD-2-Clause replacements. The compiled color values were matched by name and light/dark appearance to <code>{binding['runtimePath']}</code> (SHA-256 <code>{binding['runtimeSHA256']}</code>); verified color sets: {binding['colorCount']}.</p>\n"
            f"<p>License: <code>{prefix}/LICENSE.txt</code> (SHA-256 <code>{binding['licenseSHA256']}</code>); attribution: <code>{prefix}/ATTRIBUTION.json</code> (SHA-256 <code>{binding['attributionSHA256']}</code>).</p>\n</section>")


def _webkit_warning_colors_overlay(
    runtime_frameworks: Path | None, source_offer_root: Path | None,
) -> dict[str, object] | None:
    """Bind warning color sources to the compiled WebKit Assets.car color records."""
    if source_offer_root is None:
        return None
    if runtime_frameworks is None:
        raise NoticeError("warning-color notices require exact WebKit runtime bytes")
    name = "neantik-first-party-warning-colors-v1"
    expected_attribution = "d32332a470fdd45e4b95e83bc53758b34676c3254af94b0e401ac905fa7437cb"
    expected_license = "a8d20bbe0dc85256b9837b293af6921269f0c64362674069e63aee5e24ada814"
    offer = source_offer_root.resolve(strict=True)
    overlay = offer / "overlays" / name
    attribution_path = _physical_path_beneath(overlay, Path("ATTRIBUTION.json"),
                                               label="WebKit warning-color attribution")
    license_path = _physical_path_beneath(overlay, Path("LICENSE.txt"),
                                           label="WebKit warning-color BSD-2 license")
    if (sha256_file(attribution_path) != expected_attribution
            or sha256_file(license_path) != expected_license):
        raise NoticeError("pinned WebKit warning-color attribution or license changed")
    try:
        attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
        manifest = json.loads((offer / "manifest.json").read_text(encoding="utf-8"))
        components = manifest["sourceOfferComponents"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise NoticeError("WebKit warning-color source-offer metadata is invalid") from error
    warning_assets = attribution.get("assets")
    if (attribution.get("schemaVersion") != 1 or attribution.get("license") != "BSD-2-Clause"
            or attribution.get("assetCount") != 9 or not isinstance(warning_assets, list)
            or len(warning_assets) != 9
            or attribution.get("runtimeResourcePath") != "WebKit.framework/Versions/A/Resources/Assets.car"):
        raise NoticeError("WebKit warning-color attribution scope mismatch")
    component_map = {row.get("path"): row for row in components if isinstance(row, dict)}
    if len(component_map) != len(components):
        raise NoticeError("WebKit warning-color source-offer manifest has duplicate paths")
    expected_colors: dict[str, dict[str, tuple[float, float, float, float]]] = {}
    for row in warning_assets:
        source_path = row.get("path") if isinstance(row, dict) else None
        if (not isinstance(source_path, str) or not source_path.startswith("Source/WebKit/")
                or row.get("license") != "BSD-2-Clause"
                or row.get("runtimeResourcePath") != attribution.get("runtimeResourcePath")
                or not isinstance(row.get("copyright"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", str(row.get("sha256", "")))):
            raise NoticeError("WebKit warning-color asset attribution row is invalid")
        relative = Path(source_path)
        if relative.is_absolute() or ".." in relative.parts:
            raise NoticeError("WebKit warning-color source path is unsafe")
        source = _physical_path_beneath(overlay, relative, label="WebKit warning-color source asset")
        digest = row["sha256"]
        if source.stat().st_size != row.get("bytes") or sha256_file(source) != digest:
            raise NoticeError(f"WebKit warning-color source asset differs from attribution: {source_path}")
        component_path = f"overlays/{name}/{source_path}"
        component = component_map.get(component_path)
        if (component is None or component.get("includedInOfferFolder") is not True
                or component.get("bytes") != source.stat().st_size or component.get("sha256") != digest):
            raise NoticeError(f"WebKit warning-color source asset is not bound by offer manifest: {source_path}")
        if source_path.endswith(".colorset/Contents.json"):
            color_name = Path(source_path).parent.name.removesuffix(".colorset")
            if color_name in expected_colors:
                raise NoticeError(f"duplicate WebKit warning-color asset name: {color_name}")
            try:
                color_data = json.loads(source.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as error:
                raise NoticeError(f"WebKit warning-color catalog JSON is invalid: {source_path}") from error
            variants: dict[str, tuple[float, float, float, float]] = {}
            for color in color_data.get("colors", []):
                value = color.get("color", {}).get("components", {})
                appearance = color.get("appearances", [])
                variant = "NSAppearanceNameDarkAqua" if appearance else "Light"
                variants[variant] = tuple(float(value[channel]) for channel in ("red", "green", "blue", "alpha"))
            if len(variants) != 2 or "Light" not in variants or "NSAppearanceNameDarkAqua" not in variants:
                raise NoticeError(f"WebKit warning-color asset lacks exact light/dark variants: {source_path}")
            expected_colors[color_name] = variants
    if len(expected_colors) != 7:
        raise NoticeError("WebKit warning-color source catalog must bind exactly seven color sets")
    runtime_relative = Path("WebKit.framework/Versions/A/Resources/Assets.car")
    assets_car = _physical_path_beneath(runtime_frameworks, runtime_relative,
                                        label="compiled WebKit warning-color Assets.car")
    assetutil = shutil.which("assetutil")
    if not assetutil:
        raise NoticeError("assetutil is required to verify compiled WebKit warning-color assets")
    try:
        completed = subprocess.run([assetutil, "--info", str(assets_car)], check=True,
                                   capture_output=True, text=True, timeout=60)
        compiled = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, UnicodeError, json.JSONDecodeError) as error:
        raise NoticeError("compiled WebKit Assets.car could not be inspected with assetutil") from error
    for color_name, variants in expected_colors.items():
        rows = [item for item in compiled if isinstance(item, dict)
                and item.get("AssetType") == "Color" and item.get("Name") == color_name]
        if len(rows) != 2:
            raise NoticeError(f"compiled Assets.car color entry count mismatch: {color_name}")
        observed: dict[str, tuple[float, float, float, float]] = {}
        for item in rows:
            appearance = item.get("Appearance", "Light")
            observed[appearance] = tuple(float(value) for value in item.get("Color components", []))
        for variant, expected in variants.items():
            actual = observed.get(variant)
            if actual is None or len(actual) != 4 or any(abs(a-b) > 0.00001 for a,b in zip(actual, expected)):
                raise NoticeError(f"compiled Assets.car color does not match pinned source: {color_name}/{variant}")
    return {"name": name, "overlay": overlay, "attribution": attribution_path,
            "license": license_path, "attributionSHA256": expected_attribution,
            "licenseSHA256": expected_license, "runtimePath": runtime_relative.as_posix(),
            "runtimeSHA256": sha256_file(assets_car), "colorCount": len(expected_colors)}


def render_webcore_media_controls_markdown(review_sha256: str,
                                          overlay: dict[str, object] | None = None) -> str:
    if overlay is not None:
        return (f"{WEBCORE_MEDIA_CONTROLS_SECTION_MARKER}\n\n"
                "The 35 shipped modern-media-controls image resources are NeAntik first-party replacements. "
                "BSD-2-Clause applies only to these exact replacement bytes; upstream source art and other WebCore resources retain their separate review status.\n\n"
                f"- Runtime replacement count: `{len(overlay['runtimeAssets'])}`; each packaged resource was SHA-256 checked against the attribution manifest.\n"
                f"- License: `NeAntikRuntimeLicenses/WebCore/NeAntik-MediaControls-BSD-2-Clause.txt` "
                f"(SHA-256 `{overlay['licenseSHA256']}`).\n"
                f"- Attribution: `NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsAttribution.json` "
                f"(SHA-256 `{overlay['attributionSHA256']}`).\n"
                f"- Upstream rights-boundary review retained as historical source evidence: SHA-256 `{review_sha256}`.\n")
    return (f"{WEBCORE_MEDIA_CONTROLS_SECTION_MARKER}\n\n"
            "The 35 exact modern-media-controls image resources map byte-for-byte to the pinned WebKit source archive and first-add commits. "
            "The available WebKit policy concerns new code contributions and does not establish terms or copyright attribution for these artwork files. "
            "Their applicable license and required attribution remain UNKNOWN; this section is review evidence, not a license grant or release approval.\n\n"
            "- Rights-boundary review: `NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsRightsBoundaryReview.json` "
            f"(SHA-256 `{review_sha256}`).\n"
            "- Do not qualify or redistribute these resources until file-specific rights are established or the assets are replaced with cleared artwork.\n")


def render_webcore_media_controls_html(review_sha256: str,
                                      overlay: dict[str, object] | None = None) -> str:
    if overlay is not None:
        return (f'{WEBCORE_MEDIA_CONTROLS_HTML_MARKER}\n'
                '<h2>WebCore modern media controls image resources</h2>\n'
                '<p>The 35 shipped resources are NeAntik first-party replacements. BSD-2-Clause applies only to these exact replacement bytes; upstream source art and other WebCore resources retain separate review status.</p>\n'
                f'<p>All {len(overlay["runtimeAssets"])} runtime resources were SHA-256 checked against the attribution manifest. '
                f'License: <code>NeAntikRuntimeLicenses/WebCore/NeAntik-MediaControls-BSD-2-Clause.txt</code> '
                f'(SHA-256 <code>{overlay["licenseSHA256"]}</code>); attribution: '
                f'<code>NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsAttribution.json</code> '
                f'(SHA-256 <code>{overlay["attributionSHA256"]}</code>). Historical upstream rights review SHA-256 '
                f'<code>{review_sha256}</code>.</p>\n</section>')
    return (f'{WEBCORE_MEDIA_CONTROLS_HTML_MARKER}\n'
            '<h2>WebCore modern media controls image resources</h2>\n'
            '<p>The review maps 35 exact images byte-for-byte to the pinned WebKit source archive and first-add commits. '
            'The available policy does not establish license terms or copyright attribution for these artwork files. '
            '<strong>Applicable terms and attribution remain UNKNOWN.</strong> This is review evidence, not a license grant or release approval.</p>\n'
            '<p>Rights-boundary review: <code>NeAntikRuntimeLicenses/WebCore/MediaControlsAssetsRightsBoundaryReview.json</code> '
            f'(SHA-256 <code>{review_sha256}</code>). Do not qualify or redistribute these resources until file-specific rights are established or they are replaced with cleared artwork.</p>\n'
            '</section>')


def render_webcore_model_ibl_markdown(binding: dict[str, object]) -> str:
    return (f"{WEBCORE_MODEL_IBL_SECTION_MARKER}\n\n"
            "These two WebCore WebModel cube-map resources were generated by the NeAntik deterministic analytic environment-map generator. "
            "The BSD-2-Clause license applies to these exact first-party replacement bytes; it does not apply to the upstream bytes they replace. "
            "The replacements preserve the R16float dimensions and mip layout but change default model lighting and reflections.\n\n"
            f"- Diffuse runtime resource SHA-256: `{binding['diffuseSHA256']}`.\n"
            f"- Specular runtime resource SHA-256: `{binding['specularSHA256']}`.\n"
            f"- License: `NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-BSD-2-Clause.txt` "
            f"(SHA-256 `{WEBCORE_MODEL_IBL_LICENSE_SHA256}`).\n"
            f"- Asset attribution: `NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-Attribution.json` "
            f"(SHA-256 `{WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256}`).\n")


def render_webcore_model_ibl_html(binding: dict[str, object]) -> str:
    return (f'{WEBCORE_MODEL_IBL_HTML_MARKER}\n'
            '<h2>WebCore first-party WebModel environment resources</h2>\n'
            '<p>These deterministic NeAntik-generated R16float cube maps are licensed under BSD-2-Clause. '
            'The license does not apply to the upstream bytes they replace. Their dimensions and mip layout are preserved, '
            'but default model lighting and reflections change.</p>\n'
            '<ul>\n'
            f'<li>Diffuse runtime resource SHA-256: <code>{binding["diffuseSHA256"]}</code>.</li>\n'
            f'<li>Specular runtime resource SHA-256: <code>{binding["specularSHA256"]}</code>.</li>\n'
            f'<li>License: <code>NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-BSD-2-Clause.txt</code>; '
            f'SHA-256 <code>{WEBCORE_MODEL_IBL_LICENSE_SHA256}</code>.</li>\n'
            f'<li>Attribution: <code>NeAntikRuntimeLicenses/WebCore/NeAntik-WebModel-IBL-Attribution.json</code>; '
            f'SHA-256 <code>{WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256}</code>.</li>\n'
            '</ul>\n</section>')


def _ircam_listen_hrtf_notice(
    project_root: Path, runtime_frameworks: Path | None,
) -> dict[str, object]:
    notice = _physical_path_beneath(
        project_root, IRCAM_LISTEN_HRTF_NOTICE_SOURCE,
        label="IRCAM LISTEN HRTF permission and attribution notice")
    if sha256_file(notice) != IRCAM_LISTEN_HRTF_NOTICE_SHA256:
        raise NoticeError("IRCAM LISTEN HRTF notice differs from pinned terms summary")
    runtime_hash = IRCAM_LISTEN_HRTF_RUNTIME_SHA256
    runtime_path = None
    if runtime_frameworks is not None:
        runtime_path = _physical_path_beneath(
            runtime_frameworks, IRCAM_LISTEN_HRTF_RUNTIME_PATH,
            label="IRCAM LISTEN HRTF runtime resource")
        runtime_hash = sha256_file(runtime_path)
        if runtime_hash != IRCAM_LISTEN_HRTF_RUNTIME_SHA256:
            raise NoticeError("IRCAM LISTEN HRTF runtime resource differs from cleared source bytes")
    return {"notice": notice, "runtimePath": runtime_path,
            "runtimeSHA256": runtime_hash,
            "noticeSHA256": IRCAM_LISTEN_HRTF_NOTICE_SHA256}


def render_ircam_listen_hrtf_markdown(binding: dict[str, object]) -> str:
    return (f"{IRCAM_LISTEN_HRTF_SECTION_MARKER}\n\n"
            "The bundled WebCore HRTF data comes from the IRCAM LISTEN composite database. "
            "IRCAM's published terms permit any use and request acknowledgement of the database. "
            "IRCAM retains its stated copyright; this is a separate data permission, not an SPDX "
            "license or a relicensing of WebKit/NeAntik code.\n\n"
            f"- Runtime resource: `{IRCAM_LISTEN_HRTF_RUNTIME_PATH.as_posix()}` "
            f"(SHA-256 `{binding['runtimeSHA256']}`).\n"
            f"- Permission and attribution notice: `{IRCAM_LISTEN_HRTF_NOTICE_DESTINATION.as_posix()}` "
            f"(SHA-256 `{binding['noticeSHA256']}`).\n")


def render_ircam_listen_hrtf_html(binding: dict[str, object]) -> str:
    return (f'{IRCAM_LISTEN_HRTF_HTML_MARKER}\n'
            '<h2>IRCAM LISTEN HRTF dataset permission and attribution</h2>\n'
            '<p>The bundled WebCore HRTF data comes from the IRCAM LISTEN composite database. '
            'IRCAM published terms permit any use and request acknowledgement of the database. '
            'IRCAM retains its stated copyright. This separate data permission is not an SPDX '
            'license and does not relicense WebKit or NeAntik code.</p>\n'
            f'<p>Runtime resource: <code>{IRCAM_LISTEN_HRTF_RUNTIME_PATH.as_posix()}</code> '
            f'(SHA-256 <code>{binding["runtimeSHA256"]}</code>). Permission and attribution: '
            f'<code>{IRCAM_LISTEN_HRTF_NOTICE_DESTINATION.as_posix()}</code> '
            f'(SHA-256 <code>{binding["noticeSHA256"]}</code>).</p>\n</section>')


def render_webrtc_generated_headers_markdown() -> str:
    return (f"{WEBRTC_GENERATED_HEADERS_SECTION_MARKER}\n\n"
            "The pinned v20 libwebrtc build has 124 linked generated assembly outputs from "
            "62 hash-matched BoringSSL generator inputs with explicit Apache-2.0 headers. "
            "This preserves source attribution; component, patent and complete notice scope remain under review.\n\n"
            "- `NeAntikRuntimeLicenses/WebRTC/GeneratedInputHeaders.txt` "
            f"(SHA-256 `{WEBRTC_GENERATED_HEADERS_SHA256}`).\n")


def render_webrtc_generated_headers_html() -> str:
    return (f'{WEBRTC_GENERATED_HEADERS_HTML_MARKER}\n'
            '<h2>libwebrtc generated-input source headers</h2>\n'
            '<p>Exact v20 inputs for 124 linked generated assembly outputs: '
            '62 BoringSSL generators with explicit Apache-2.0 headers. '
            'Component, patent and complete notice scope remain under review.</p>\n'
            '<p>Packaged evidence: <code>NeAntikRuntimeLicenses/WebRTC/GeneratedInputHeaders.txt</code>; '
            f'SHA-256 <code>{WEBRTC_GENERATED_HEADERS_SHA256}</code>.</p>\n</section>')


def _verify_private_v446_evidence(offer: Path, source: Path, baseline: Path,
                                  modified: Path, signed: Path, binding: Path,
                                  v508_receipt: Path | None = None) -> dict:
    validator_path = Path(__file__).resolve().parent / "verify-recipient-v446-capability.py"
    spec = importlib.util.spec_from_file_location("neantik_private_v446_notice_validator", validator_path)
    if spec is None or spec.loader is None:
        raise NoticeError("private V446 QA validator unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
        if v508_receipt is None:
            return module.verify(offer, source, baseline, modified, signed, binding)
        return module.verify(offer, source, baseline, modified, signed, binding,
                             v508_receipt=v508_receipt)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise NoticeError("private V446 QA evidence validation failed") from error


def private_v446_dev_qa_notices(
    action: str, app: Path, runtime_frameworks: Path, *, source_offer_root: Path,
    source: Path, baseline: Path, modified: Path, binding: Path,
    v508_receipt: Path | None = None,
    project_root: Path = PROJECT_ROOT,
):
    """Run one narrowly bound private QA notice action, never a production override.

    Each action revalidates the exact V446 inputs and signed runtime. It is not
    a production packaging API, source/build attestation, or release approval.
    """
    if action not in ("preflight", "install", "verify"):
        raise NoticeError("private V446 QA action invalid")
    if app.is_symlink() or not app.is_dir():
        raise NoticeError("private V446 QA requires a physical Dev app")
    info = _safe_destination(app, Path("Contents/Info.plist"), create_parent=False)
    _physical_file(info, label="private V446 QA Dev Info.plist")
    try:
        with info.open("rb") as stream:
            metadata = plistlib.load(stream)
        if not isinstance(metadata, dict) or metadata.get("CFBundleIdentifier") != "app.neantik.desktop.dev":
            raise ValueError("not the separate Dev bundle")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise NoticeError("private V446 QA requires the separate Dev bundle identity") from error
    if runtime_frameworks.is_symlink() or not runtime_frameworks.is_dir():
        raise NoticeError("private V446 QA requires physical runtime Frameworks")
    result = _verify_private_v446_evidence(source_offer_root, source, baseline, modified,
                                           runtime_frameworks, binding, v508_receipt)
    if (not isinstance(result, dict) or result.get("status") != "private-v446-evidence-pass"
            or result.get("releaseQualified") is not False
            or result.get("offerManifestSHA256") != "988f05c617ac7ddf460c37ac5de3537f2fb7b5bc60cf0dbfa634aed951f63faf"
            or result.get("bindingSHA256") not in {
                "af956997d6c3b1f87514899dfc9a164e698cecae583942dfa0d1a83d0b07673d",
                "c4264d49e80670c09cf769f4031fae9740cbc1accfa5d37372b78d270b0df39a"}
            or result.get("imageCount") != 16):
        raise NoticeError("private V446 QA evidence identity mismatch")
    token = _CURRENT_PRIVATE_V446_QA.set(True)
    try:
        function = {"preflight": preflight_owned_webkit_notices,
                    "install": install_owned_webkit_notices,
                    "verify": verify_owned_webkit_notices}[action]
        return function(app, runtime_frameworks, project_root=project_root,
                        source_offer_root=source_offer_root,
                        source_offer_manifest_sha256=result["offerManifestSHA256"])
    finally:
        _CURRENT_PRIVATE_V446_QA.reset(token)


def preflight_owned_webkit_notices(
    app: Path, runtime_frameworks: Path, *, project_root: Path = PROJECT_ROOT,
    source_offer_root: Path | None = None,
    source_offer_manifest_sha256: str | None = None,
) -> None:
    """Validate notice inputs in a disposable app before changing the signed app."""
    with tempfile.TemporaryDirectory(prefix="neantik-webkit-notice-preflight-") as temporary:
        scratch = Path(temporary) / "NeAntik.app"
        for relative in (NOTICE_DESTINATION, HTML_DESTINATION):
            source = _safe_destination(app, relative, create_parent=False)
            _physical_file(source, label=f"app notice {relative}")
            destination = scratch / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        install_owned_webkit_notices(scratch, runtime_frameworks, project_root=project_root,
                                     source_offer_root=source_offer_root,
                                     source_offer_manifest_sha256=source_offer_manifest_sha256)


@_with_v382_runtime_hashes
def install_owned_webkit_notices(
    app: Path, runtime_frameworks: Path, *, project_root: Path = PROJECT_ROOT,
    source_offer_root: Path | None = None,
) -> dict[str, str]:
    """Copy hash-pinned license texts and add scoped Markdown/HTML notices."""
    _validate_v135_runtime_binding_evidence(project_root)
    webgpu_license = _webgpu_license(project_root)
    webgpu_adapter_header = _webgpu_adapter_header(project_root)
    webgpu_image = _webgpu_image(runtime_frameworks)
    webgpu_hash = _runtime_image_build_sha(
        runtime_frameworks, WEBGPU_IMAGE_PATH, WEBGPU_IMAGE_SHA256)
    jsc_bsd2_license, jsc_bsd2_review_path, jsc_bsd2_review = (
        _jsc_headerless_bsd2_sources(project_root))
    jsc_bsd2_image = _jsc_headerless_bsd2_image(runtime_frameworks, jsc_bsd2_review)
    jsc_bsd2_image_hash = _runtime_image_build_sha(
        runtime_frameworks, Path("JavaScriptCore.framework/Versions/A/JavaScriptCore"),
        jsc_bsd2_review["sourceBinding"]["runtimeImageSHA256"])
    jsc_bsd2_review_hash = sha256_file(jsc_bsd2_review_path)
    jsc_generated_output_manifest_path, jsc_generated_output_headers_path, jsc_generated_output_manifest = (
        _jsc_generated_output_notices(project_root, runtime_frameworks))
    jsc_copying_lib = _jsc_copying_lib_license(project_root)
    jsc_binja_attribution, jsc_binja_apache = _jsc_binja_license_sources(project_root)
    source_license = _license(project_root)
    source_lgpl2 = _webcore_lgpl2_license(project_root)
    source_lgpl21 = _webcore_lgpl21_license(project_root)
    jsc_tri_license_sources = _jsc_tri_license_texts(project_root)
    jsc_unicode_license, jsc_lineage = _jsc_unicode_sources(project_root)
    angle_notice_sources = _angle_notice_sources(project_root)
    webrtc_manifest, webrtc_notices = _webrtc_notice_sources(project_root)
    source_webrtc_mpl2 = _webrtc_mpl2_license(project_root)
    source_libwebm_authors = _webrtc_libwebm_authors(project_root)
    source_dav1d_headers = _dav1d_headers(project_root)
    source_rnnoise_header = _rnnoise_header(project_root)
    source_libsrtp_headers = _libsrtp_headers(project_root)
    source_opus_headers = _opus_headers(project_root)
    linked_headers_manifest, linked_header_sources = _linked_source_header_notices(project_root)
    webcore_popover_license, webcore_popover_review = _webcore_popover_notice_sources(
        project_root, linked_headers_manifest)
    webcore_popover_review_hash = sha256_file(webcore_popover_review)
    webcore_colordata_license, webcore_colordata_review = _webcore_colordata_notice_sources(
        project_root, linked_headers_manifest)
    webcore_colordata_review_hash = sha256_file(webcore_colordata_review)
    webcore_css_apple_license, webcore_css_lgpl2_license, webcore_css_review = (
        _webcore_css_generated_notice_sources(project_root, linked_headers_manifest))
    webcore_css_review_hash = sha256_file(webcore_css_review)
    webcore_media_review = _webcore_media_controls_notice_sources(project_root)
    webcore_media_review_hash = sha256_file(webcore_media_review)
    webcore_media_overlay = _webcore_media_controls_overlay(
        project_root, runtime_frameworks, source_offer_root)
    webcore_model_ibl = _webcore_model_ibl_notice_sources(project_root, runtime_frameworks)
    ircam_listen_hrtf = _ircam_listen_hrtf_notice(project_root, runtime_frameworks)
    webcore_first_party = _webcore_first_party_resource_overlays(runtime_frameworks, source_offer_root)
    webkit_warning_colors = _webkit_warning_colors_overlay(runtime_frameworks, source_offer_root)
    webcore_generated_headers = _physical_path_beneath(
        project_root, WEBCORE_GENERATED_HEADERS_SOURCE,
        label="pinned WebCore generated-input headers")
    if sha256_file(webcore_generated_headers) != WEBCORE_GENERATED_HEADERS_SHA256:
        raise NoticeError("pinned WebCore generated-input headers SHA-256 mismatch")
    webrtc_generated_headers = _physical_path_beneath(
        project_root, WEBRTC_GENERATED_HEADERS_SOURCE,
        label="pinned libwebrtc generated-input headers")
    if sha256_file(webrtc_generated_headers) != WEBRTC_GENERATED_HEADERS_SHA256:
        raise NoticeError("pinned libwebrtc generated-input headers SHA-256 mismatch")
    _webinspector_notice_sources(project_root, runtime_frameworks)
    sandbox_rows = _sandbox_notice_sources(project_root)
    source_candidate_manifest, source_candidate_manifest_bytes, source_candidate_sources = (
        _source_candidate_notice_sources(project_root, source_offer_root, runtime_frameworks))
    webkit_swift_manifest, webkit_swift_manifest_bytes, webkit_swift_sources = (
        _webkit_swift_source_notice_sources(project_root))
    webkit_xpc_notice_source, webkit_xpc_map, webkit_xpc_notice_bytes = (
        _webkit_xpc_entrypoint_notice(project_root))
    _verify_webkit_swift_runtime_images(runtime_frameworks, webkit_swift_manifest)
    library = _compatibility_span(runtime_frameworks)
    library_hash = _runtime_image_build_sha(
        runtime_frameworks, _runtime_relative_path(runtime_frameworks, library), None)
    angle_library = _angle_library(runtime_frameworks)
    angle_hash = _runtime_image_build_sha(
        runtime_frameworks, _runtime_relative_path(runtime_frameworks, angle_library), None)
    webrtc_library = _webrtc_library(runtime_frameworks)
    webrtc_hash = _runtime_image_build_sha(
        runtime_frameworks, _runtime_relative_path(runtime_frameworks, webrtc_library), None)
    markdown = _safe_destination(app, NOTICE_DESTINATION, create_parent=False)
    html_notice = _safe_destination(app, HTML_DESTINATION, create_parent=False)
    packaged_license = _safe_destination(app, LICENSE_DESTINATION, create_parent=True)
    packaged_webinspector_framework_license = _safe_destination(
        app, WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION, create_parent=True)
    packaged_webkit_xpc_notice = _safe_destination(
        app, WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION, create_parent=True)
    packaged_lgpl2 = _safe_destination(app, WEBCORE_LGPL2_DESTINATION, create_parent=True)
    packaged_lgpl21 = _safe_destination(app, WEBCORE_LGPL21_DESTINATION, create_parent=True)
    packaged_jsc_copying_lib = _safe_destination(
        app, JSC_COPYING_LIB_DESTINATION, create_parent=True)
    packaged_jsc_binja_attribution = _safe_destination(
        app, JSC_BINJA_ATTRIBUTION_DESTINATION, create_parent=True)
    packaged_jsc_binja_apache = _safe_destination(
        app, JSC_BINJA_APACHE_DESTINATION, create_parent=True)
    packaged_jsc_tri_licenses = [
        _safe_destination(app, destination, create_parent=True)
        for _source, _digest, destination in jsc_tri_license_sources
    ]
    packaged_jsc_unicode_license = _safe_destination(
        app, JSC_UNICODE_LICENSE_DESTINATION, create_parent=True)
    packaged_jsc_lineage = _safe_destination(
        app, JSC_GENERATED_LINEAGE_DESTINATION, create_parent=True)
    packaged_jsc_generated_output_manifest = _safe_destination(
        app, JSC_GENERATED_OUTPUT_DESTINATION_ROOT / "Manifest.json", create_parent=True)
    packaged_jsc_generated_output_headers = _safe_destination(
        app, JSC_GENERATED_OUTPUT_DESTINATION_ROOT / "GeneratedOutputHeaders.txt", create_parent=True)
    packaged_angle_licenses = [
        _safe_destination(app, destination, create_parent=True)
        for _source, _name, _expected_hash, destination in angle_notice_sources
    ]
    packaged_webrtc_manifest = _safe_destination(
        app, WEBRTC_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_webrtc_mpl2 = _safe_destination(
        app, WEBRTC_MPL2_DESTINATION, create_parent=True)
    packaged_libwebm_authors = _safe_destination(
        app, WEBRTC_LIBWEBM_AUTHORS_DESTINATION, create_parent=True)
    packaged_dav1d_headers = _safe_destination(app, DAV1D_HEADERS_DESTINATION, create_parent=True)
    packaged_rnnoise_header = _safe_destination(app, RNNOISE_HEADER_DESTINATION, create_parent=True)
    packaged_libsrtp_headers = _safe_destination(app, LIBSRTP_HEADERS_DESTINATION, create_parent=True)
    packaged_opus_headers = _safe_destination(app, OPUS_HEADERS_DESTINATION, create_parent=True)
    packaged_linked_headers_manifest = _safe_destination(
        app, LINKED_HEADERS_DESTINATION_ROOT / "MANIFEST.json", create_parent=True)
    packaged_linked_headers = [
        _safe_destination(app, LINKED_HEADERS_DESTINATION_ROOT / row["noticePath"],
                          create_parent=True)
        for row in linked_headers_manifest["images"]
    ]
    packaged_webcore_generated_headers = _safe_destination(
        app, WEBCORE_GENERATED_HEADERS_DESTINATION, create_parent=True)
    packaged_webcore_popover_license = _safe_destination(
        app, WEBCORE_POPOVER_LICENSE_DESTINATION, create_parent=True)
    packaged_webcore_popover_review = _safe_destination(
        app, WEBCORE_POPOVER_REVIEW_DESTINATION, create_parent=True)
    packaged_webcore_colordata_license = _safe_destination(
        app, WEBCORE_COLORDATA_LICENSE_DESTINATION, create_parent=True)
    packaged_webcore_colordata_review = _safe_destination(
        app, WEBCORE_COLORDATA_REVIEW_DESTINATION, create_parent=True)
    packaged_webcore_css_apple_license = _safe_destination(
        app, WEBCORE_CSS_GENERATED_APPLE_LICENSE_DESTINATION, create_parent=True)
    packaged_webcore_css_review = _safe_destination(
        app, WEBCORE_CSS_GENERATED_REVIEW_DESTINATION, create_parent=True)
    packaged_webcore_media_review = _safe_destination(
        app, WEBCORE_MEDIA_CONTROLS_REVIEW_DESTINATION, create_parent=True)
    packaged_webcore_media_overlay_license = (
        _safe_destination(app, WEBCORE_MEDIA_CONTROLS_OVERLAY_LICENSE_DESTINATION, create_parent=True)
        if webcore_media_overlay is not None else None)
    packaged_webcore_media_overlay_attribution = (
        _safe_destination(app, WEBCORE_MEDIA_CONTROLS_OVERLAY_ATTRIBUTION_DESTINATION, create_parent=True)
        if webcore_media_overlay is not None else None)
    packaged_webcore_model_ibl_license = (
        _safe_destination(app, WEBCORE_MODEL_IBL_LICENSE_DESTINATION, create_parent=True)
        if webcore_model_ibl is not None else None)
    packaged_webcore_model_ibl_attribution = (
        _safe_destination(app, WEBCORE_MODEL_IBL_ATTRIBUTION_DESTINATION, create_parent=True)
        if webcore_model_ibl is not None else None)
    packaged_ircam_listen_hrtf_notice = _safe_destination(
        app, IRCAM_LISTEN_HRTF_NOTICE_DESTINATION, create_parent=True)
    packaged_webcore_first_party = ([
        (_safe_destination(app, WEBCORE_FIRST_PARTY_NOTICE_ROOT / str(row["name"]) / "LICENSE.txt", create_parent=True),
         _safe_destination(app, WEBCORE_FIRST_PARTY_NOTICE_ROOT / str(row["name"]) / "ATTRIBUTION.json", create_parent=True))
        for row in webcore_first_party] if webcore_first_party is not None else [])
    packaged_webkit_warning_colors = (
        (_safe_destination(app, WEBKIT_WARNING_COLOR_NOTICE_ROOT / str(webkit_warning_colors["name"]) / "LICENSE.txt", create_parent=True),
         _safe_destination(app, WEBKIT_WARNING_COLOR_NOTICE_ROOT / str(webkit_warning_colors["name"]) / "ATTRIBUTION.json", create_parent=True))
        if webkit_warning_colors is not None else None)
    packaged_webrtc_generated_headers = _safe_destination(
        app, WEBRTC_GENERATED_HEADERS_DESTINATION, create_parent=True)
    packaged_webrtc_notices = [
        _safe_destination(app, WEBRTC_NOTICE_ROOT / output_relative, create_parent=True)
        for _source_relative, output_relative, _digest, _size in webrtc_notices
    ]
    packaged_sandbox_manifest = _safe_destination(
        app, SANDBOX_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_sandbox_sources = [
        _safe_destination(app, SANDBOX_NOTICE_ROOT / name, create_parent=True)
        for name, _source_path, _runtime_path, _size in sandbox_rows
    ]
    packaged_source_candidate_manifest = _safe_destination(
        app, SOURCE_CANDIDATE_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_source_candidate_files = [
        _safe_destination(app, SOURCE_CANDIDATE_NOTICE_ROOT / row["outputPath"],
                          create_parent=True)
        for row in source_candidate_manifest["entries"]
    ]
    packaged_webkit_swift_manifest = _safe_destination(
        app, WEBKIT_SWIFT_NOTICE_ROOT / "MANIFEST.json", create_parent=True)
    packaged_webkit_swift_headers = [
        _safe_destination(app, WEBKIT_SWIFT_NOTICE_ROOT / row["outputPath"],
                          create_parent=True)
        for row in webkit_swift_manifest["entries"]
    ]
    packaged_webgpu_license = _safe_destination(
        app, WEBGPU_LICENSE_DESTINATION, create_parent=True)
    packaged_webgpu_adapter_header = _safe_destination(app, WEBGPU_ADAPTER_HEADER_DESTINATION, create_parent=True)
    packaged_jsc_bsd2_license = _safe_destination(
        app, JSC_HEADERLESS_BSD2_LICENSE_DESTINATION, create_parent=True)
    packaged_jsc_bsd2_review = _safe_destination(
        app, JSC_HEADERLESS_BSD2_REVIEW_DESTINATION, create_parent=True)
    original_markdown = markdown.read_text(encoding="utf-8")
    original_html_bytes = html_notice.read_bytes()
    compliance_manifest = _compliance_manifest(app, original_html_bytes)
    original_html = original_html_bytes.decode("utf-8")
    markdown_text = _remove_owned_markdown_sections(original_markdown)
    html_text = _remove_owned_html_sections(original_html)
    section = render_markdown(library_hash)
    html_section = render_html(library_hash)
    lgpl2_markdown = render_lgpl2_markdown()
    lgpl2_html = render_lgpl2_html()
    jsc_copying_lib_markdown = render_jsc_copying_lib_markdown()
    jsc_copying_lib_html = render_jsc_copying_lib_html()
    jsc_binja_markdown = render_jsc_binja_markdown()
    jsc_binja_html = render_jsc_binja_html()
    lgpl21_markdown = render_lgpl21_markdown()
    lgpl21_html = render_lgpl21_html()
    jsc_tri_license_markdown = render_jsc_tri_license_markdown()
    jsc_tri_license_html = render_jsc_tri_license_html()
    jsc_unicode_markdown = render_jsc_unicode_markdown()
    jsc_unicode_html = render_jsc_unicode_html()
    angle_markdown = render_angle_markdown(angle_hash)
    angle_html = render_angle_html(angle_hash)
    webrtc_markdown = render_webrtc_markdown(webrtc_hash, webrtc_manifest, webrtc_notices)
    webrtc_html = render_webrtc_html(webrtc_hash, webrtc_manifest, webrtc_notices)
    linked_headers_markdown = render_linked_headers_markdown(linked_headers_manifest)
    linked_headers_html = render_linked_headers_html(linked_headers_manifest)
    webcore_generated_headers_markdown = render_webcore_generated_headers_markdown()
    webcore_generated_headers_html = render_webcore_generated_headers_html()
    webcore_popover_markdown = render_webcore_popover_markdown(webcore_popover_review_hash)
    webcore_popover_html = render_webcore_popover_html(webcore_popover_review_hash)
    webcore_colordata_markdown = render_webcore_colordata_markdown(webcore_colordata_review_hash)
    webcore_colordata_html = render_webcore_colordata_html(webcore_colordata_review_hash)
    webcore_css_generated_markdown = render_webcore_css_generated_markdown(webcore_css_review_hash)
    webcore_css_generated_html = render_webcore_css_generated_html(webcore_css_review_hash)
    webcore_media_markdown = render_webcore_media_controls_markdown(
        webcore_media_review_hash, webcore_media_overlay)
    webcore_media_html = render_webcore_media_controls_html(
        webcore_media_review_hash, webcore_media_overlay)
    webcore_model_ibl_markdown = (
        render_webcore_model_ibl_markdown(webcore_model_ibl)
        if webcore_model_ibl is not None else "")
    webcore_model_ibl_html = (
        render_webcore_model_ibl_html(webcore_model_ibl)
        if webcore_model_ibl is not None else "")
    ircam_listen_hrtf_markdown = render_ircam_listen_hrtf_markdown(ircam_listen_hrtf)
    ircam_listen_hrtf_html = render_ircam_listen_hrtf_html(ircam_listen_hrtf)
    webcore_first_party_markdown = render_webcore_first_party_markdown(webcore_first_party)
    webcore_first_party_html = render_webcore_first_party_html(webcore_first_party)
    webkit_warning_color_markdown = render_webkit_warning_color_markdown(webkit_warning_colors)
    webkit_warning_color_html = render_webkit_warning_color_html(webkit_warning_colors)
    webrtc_generated_headers_markdown = render_webrtc_generated_headers_markdown()
    webrtc_generated_headers_html = render_webrtc_generated_headers_html()
    webinspector_markdown = render_webinspector_markdown()
    webinspector_html = render_webinspector_html()
    webinspector_framework_markdown = render_webinspector_framework_markdown()
    webinspector_framework_html = render_webinspector_framework_html()
    webkit_xpc_markdown = render_webkit_xpc_entrypoint_markdown(webkit_xpc_map)
    webkit_xpc_html = render_webkit_xpc_entrypoint_html(webkit_xpc_map)
    sandbox_markdown = render_sandbox_markdown(sandbox_rows)
    sandbox_html = render_sandbox_html(sandbox_rows)
    source_candidate_markdown = render_source_candidate_markdown(source_candidate_manifest)
    source_candidate_html = render_source_candidate_html(source_candidate_manifest)
    webkit_swift_markdown = render_webkit_swift_source_markdown(
        webkit_swift_manifest, webkit_swift_sources)
    webkit_swift_html = render_webkit_swift_source_html(
        webkit_swift_manifest, webkit_swift_sources)
    webgpu_markdown = render_webgpu_markdown(webgpu_hash)
    webgpu_html = render_webgpu_html(webgpu_hash)
    jsc_bsd2_markdown = render_jsc_headerless_bsd2_markdown(
        jsc_bsd2_image_hash, jsc_bsd2_review_hash)
    jsc_bsd2_html = render_jsc_headerless_bsd2_html(
        jsc_bsd2_image_hash, jsc_bsd2_review_hash)
    jsc_generated_output_markdown = render_jsc_generated_output_markdown(
        jsc_generated_output_manifest)
    jsc_generated_output_html = render_jsc_generated_output_html(
        jsc_generated_output_manifest)
    lowered_html = html_text.lower()
    closing_body = lowered_html.rfind("</body>")
    if closing_body >= 0:
        insertion_point = closing_body
    else:
        # Chromium's generated THIRD-PARTY-NOTICES.html is an HTML fragment:
        # it opens <body> and intentionally omits closing body/html tags.
        # Place the notice before </html> when present, or at EOF for that
        # fragment form. Refuse a document with no body at all.
        if re.search(r"<body(?:\s[^>]*)?>", lowered_html) is None:
            raise NoticeError("generated third-party HTML notice has no body element")
        closing_html = lowered_html.rfind("</html>")
        insertion_point = closing_html if closing_html >= 0 else len(html_text)
    new_html = (
        html_text[:insertion_point] + html_section + "\n" + lgpl2_html + "\n"
        + jsc_copying_lib_html + "\n"
        + jsc_binja_html + "\n"
        + lgpl21_html + "\n"
        + jsc_tri_license_html + "\n"
        + jsc_bsd2_html + "\n"
        + jsc_generated_output_html + "\n"
        + jsc_unicode_html + "\n"
        + angle_html + "\n"
        + webrtc_html + "\n"
        + linked_headers_html + "\n"
        + webcore_generated_headers_html + "\n"
        + webcore_popover_html + "\n"
        + webcore_colordata_html + "\n"
        + webcore_css_generated_html + "\n"
        + webcore_media_html + "\n"
        + webcore_model_ibl_html + "\n"
        + ircam_listen_hrtf_html + "\n"
        + ((webcore_first_party_html + "\n") if webcore_first_party_html else "")
        + ((webkit_warning_color_html + "\n") if webkit_warning_color_html else "")
        + webrtc_generated_headers_html + "\n"
        + webinspector_html + "\n"
        + webinspector_framework_html + "\n"
        + webkit_xpc_html + "\n"
        + sandbox_html + "\n"
        + source_candidate_html + "\n"
        + webkit_swift_html + "\n"
        + webgpu_html + "\n"
        + html_text[insertion_point:]
    )
    # Validate every input and destination before the first write.
    if (sha256_file(source_license) != LICENSE_SHA256
            or sha256_file(webgpu_license) != WEBGPU_LICENSE_SHA256
            or _runtime_image_build_sha(runtime_frameworks, WEBGPU_IMAGE_PATH,
                                        WEBGPU_IMAGE_SHA256)
                != _current_runtime_hash(WEBGPU_IMAGE_PATH, WEBGPU_IMAGE_SHA256)
            or sha256_file(jsc_bsd2_license) != JSC_HEADERLESS_BSD2_LICENSE_SHA256
            or sha256_file(jsc_bsd2_review_path) != JSC_HEADERLESS_BSD2_REVIEW_SHA256
            or _runtime_image_build_sha(
                runtime_frameworks, Path("JavaScriptCore.framework/Versions/A/JavaScriptCore"),
                jsc_bsd2_review["sourceBinding"]["runtimeImageSHA256"])
            != _current_runtime_hash(
                "JavaScriptCore.framework/Versions/A/JavaScriptCore",
                jsc_bsd2_review["sourceBinding"]["runtimeImageSHA256"])
            or sha256_file(source_lgpl2) != WEBCORE_LGPL2_SHA256
            or sha256_file(source_lgpl21) != WEBCORE_LGPL21_SHA256
            or _runtime_image_build_sha(
                runtime_frameworks, _runtime_relative_path(runtime_frameworks, angle_library), None)
            != angle_hash
            or _runtime_image_build_sha(
                runtime_frameworks, _runtime_relative_path(runtime_frameworks, webrtc_library), None)
            != webrtc_hash
            or sha256_file(source_webrtc_mpl2) != WEBRTC_MPL2_SHA256
            or hashlib.sha256((project_root / WEBRTC_MANIFEST_SOURCE).read_bytes()).hexdigest()
            != WEBRTC_MANIFEST_SHA256):
        raise NoticeError("a pinned runtime license text changed during packaging")
    if (webcore_model_ibl is not None
            and (sha256_file(webcore_model_ibl["license"]) != WEBCORE_MODEL_IBL_LICENSE_SHA256
                 or sha256_file(webcore_model_ibl["attribution"])
                 != WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256)):
        raise NoticeError("pinned first-party WebModel license/attribution changed during packaging")
    if sha256_file(webcore_media_review) != WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256:
        raise NoticeError("pinned WebCore media-controls rights review changed during packaging")
    for source, expected_hash, _destination in jsc_tri_license_sources:
        if sha256_file(source) != expected_hash:
            raise NoticeError(f"pinned JavaScriptCore license text changed during packaging: {source.name}")
    if (sha256_file(jsc_unicode_license) != JSC_UNICODE_LICENSE_SHA256
            or sha256_file(jsc_lineage) != JSC_GENERATED_LINEAGE_SHA256):
        raise NoticeError("pinned JavaScriptCore Unicode notice inputs changed during packaging")
    for relative, _name, expected_hash, _destination in angle_notice_sources:
        source = project_root / relative
        if sha256_file(source) != expected_hash:
            raise NoticeError(f"pinned WebKit license text changed during packaging: {relative}")
    for source_relative, output_relative, digest, size in webrtc_notices:
        source = _physical_path_beneath(
            project_root / WEBRTC_CANDIDATE_ROOT, output_relative,
            label=f"pinned WebRTC notice {source_relative}")
        if source.stat().st_size != size or sha256_file(source) != digest:
            raise NoticeError(f"pinned WebRTC notice changed during packaging: {source_relative}")
    _webinspector_notice_sources(project_root, runtime_frameworks)
    _sandbox_notice_sources(project_root)
    _webkit_swift_source_notice_sources(project_root)
    _atomic_write(packaged_license, source_license.read_bytes(), mode=0o644)
    framework_license_source = project_root / WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE
    _atomic_write(packaged_webinspector_framework_license,
                  framework_license_source.read_bytes(), mode=0o644)
    _atomic_write(packaged_webkit_xpc_notice, webkit_xpc_notice_bytes, mode=0o644)
    _atomic_write(packaged_webgpu_license, webgpu_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_webgpu_adapter_header, webgpu_adapter_header.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_bsd2_license, jsc_bsd2_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_bsd2_review, jsc_bsd2_review_path.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_generated_output_manifest,
                  jsc_generated_output_manifest_path.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_generated_output_headers,
                  jsc_generated_output_headers_path.read_bytes(), mode=0o644)
    _atomic_write(packaged_lgpl2, source_lgpl2.read_bytes(), mode=0o644)
    _atomic_write(packaged_lgpl21, source_lgpl21.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_copying_lib, jsc_copying_lib.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_binja_attribution, jsc_binja_attribution.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_binja_apache, jsc_binja_apache.read_bytes(), mode=0o644)
    for (source, _expected_hash, _destination), packaged in zip(
            jsc_tri_license_sources, packaged_jsc_tri_licenses):
        _atomic_write(packaged, source.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_unicode_license, jsc_unicode_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_jsc_lineage, jsc_lineage.read_bytes(), mode=0o644)
    for (relative, _name, _expected_hash, _destination), packaged in zip(
            angle_notice_sources, packaged_angle_licenses):
        _atomic_write(packaged, (project_root / relative).read_bytes(), mode=0o644)
    _atomic_write(packaged_webrtc_manifest, (project_root / WEBRTC_MANIFEST_SOURCE).read_bytes(), mode=0o644)
    _atomic_write(packaged_webrtc_mpl2, source_webrtc_mpl2.read_bytes(), mode=0o644)
    _atomic_write(packaged_libwebm_authors, source_libwebm_authors.read_bytes(), mode=0o644)
    _atomic_write(packaged_dav1d_headers, source_dav1d_headers.read_bytes(), mode=0o644)
    _atomic_write(packaged_rnnoise_header, source_rnnoise_header.read_bytes(), mode=0o644)
    _atomic_write(packaged_libsrtp_headers, source_libsrtp_headers.read_bytes(), mode=0o644)
    _atomic_write(packaged_opus_headers, source_opus_headers.read_bytes(), mode=0o644)
    _atomic_write(packaged_linked_headers_manifest,
                  (project_root / LINKED_HEADERS_MANIFEST_SOURCE).read_bytes(),
                  mode=0o644)
    for (source, _digest, _size), packaged in zip(linked_header_sources, packaged_linked_headers):
        _atomic_write(packaged, source.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_generated_headers,
                  webcore_generated_headers.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_popover_license,
                  webcore_popover_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_popover_review,
                  webcore_popover_review.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_colordata_license,
                  webcore_colordata_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_colordata_review,
                  webcore_colordata_review.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_css_apple_license,
                  webcore_css_apple_license.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_css_review,
                  webcore_css_review.read_bytes(), mode=0o644)
    _atomic_write(packaged_webcore_media_review,
                  webcore_media_review.read_bytes(), mode=0o644)
    if webcore_media_overlay is not None:
        assert packaged_webcore_media_overlay_license is not None
        assert packaged_webcore_media_overlay_attribution is not None
        _atomic_write(packaged_webcore_media_overlay_license,
                      webcore_media_overlay["license"].read_bytes(), mode=0o644)
        _atomic_write(packaged_webcore_media_overlay_attribution,
                      webcore_media_overlay["attribution"].read_bytes(), mode=0o644)
    if webcore_model_ibl is not None:
        assert packaged_webcore_model_ibl_license is not None
        assert packaged_webcore_model_ibl_attribution is not None
        _atomic_write(packaged_webcore_model_ibl_license,
                      webcore_model_ibl["license"].read_bytes(), mode=0o644)
        _atomic_write(packaged_webcore_model_ibl_attribution,
                      webcore_model_ibl["attribution"].read_bytes(), mode=0o644)
    _atomic_write(packaged_ircam_listen_hrtf_notice,
                  ircam_listen_hrtf["notice"].read_bytes(), mode=0o644)
    if webcore_first_party is not None:
        for row, (license_destination, attribution_destination) in zip(
                webcore_first_party, packaged_webcore_first_party):
            _atomic_write(license_destination, row["license"].read_bytes(), mode=0o644)
            _atomic_write(attribution_destination, row["attribution"].read_bytes(), mode=0o644)
    if webkit_warning_colors is not None:
        assert packaged_webkit_warning_colors is not None
        _atomic_write(packaged_webkit_warning_colors[0], webkit_warning_colors["license"].read_bytes(), mode=0o644)
        _atomic_write(packaged_webkit_warning_colors[1], webkit_warning_colors["attribution"].read_bytes(), mode=0o644)
    _atomic_write(packaged_webrtc_generated_headers,
                  webrtc_generated_headers.read_bytes(), mode=0o644)
    for (_source_relative, output_relative, _digest, _size), packaged in zip(
            webrtc_notices, packaged_webrtc_notices):
        source = project_root / WEBRTC_CANDIDATE_ROOT / output_relative
        _atomic_write(packaged, source.read_bytes(), mode=0o644)
    _atomic_write(packaged_sandbox_manifest,
                  (project_root / SANDBOX_SOURCE_ROOT / "MANIFEST.json").read_bytes(), mode=0o644)
    for (name, _source_path, _runtime_path, _size), packaged in zip(
            sandbox_rows, packaged_sandbox_sources):
        _atomic_write(packaged, (project_root / SANDBOX_SOURCE_ROOT / name).read_bytes(), mode=0o644)
    _atomic_write(packaged_source_candidate_manifest, source_candidate_manifest_bytes, mode=0o644)
    for (_source_path, source, expected_hash, expected_size), packaged in zip(
            source_candidate_sources, packaged_source_candidate_files):
        data = source.read_bytes()
        if len(data) != expected_size or hashlib.sha256(data).hexdigest() != expected_hash:
            raise NoticeError("WebKit source license candidate changed during packaging")
        _atomic_write(packaged, data, mode=0o644)
    _atomic_write(packaged_webkit_swift_manifest, webkit_swift_manifest_bytes, mode=0o644)
    for (_source_path, source, expected_hash, expected_size), packaged in zip(
            webkit_swift_sources, packaged_webkit_swift_headers):
        data = source.read_bytes()
        if len(data) != expected_size or hashlib.sha256(data).hexdigest() != expected_hash:
            raise NoticeError("WebKitSwift source header changed during packaging")
        _atomic_write(packaged, data, mode=0o644)
    new_markdown = (markdown_text.rstrip() + "\n\n" + section + "\n"
                    + lgpl2_markdown + "\n" + lgpl21_markdown + "\n"
                    + jsc_copying_lib_markdown + "\n"
                    + jsc_binja_markdown + "\n"
                    + jsc_tri_license_markdown + "\n"
                    + jsc_bsd2_markdown + "\n"
                    + jsc_generated_output_markdown + "\n"
                    + jsc_unicode_markdown + "\n"
                    + angle_markdown + "\n" + webrtc_markdown + "\n"
                    + linked_headers_markdown + "\n"
                    + webcore_generated_headers_markdown + "\n"
                    + webcore_popover_markdown + "\n"
                    + webcore_colordata_markdown + "\n"
                    + webcore_css_generated_markdown + "\n"
                    + webcore_media_markdown + "\n"
                    + webcore_model_ibl_markdown + "\n"
                    + ircam_listen_hrtf_markdown + "\n"
                    + webcore_first_party_markdown + "\n"
                    + webkit_warning_color_markdown + "\n"
                    + webrtc_generated_headers_markdown + "\n"
                    + webinspector_markdown + "\n"
                    + webinspector_framework_markdown + "\n"
                    + webkit_xpc_markdown + "\n"
                    + sandbox_markdown + "\n"
                    + source_candidate_markdown + "\n"
                    + webkit_swift_markdown + "\n"
                    + webgpu_markdown)
    _atomic_write(markdown, new_markdown.encode("utf-8"))
    new_html_bytes = new_html.encode("utf-8")
    _atomic_write(html_notice, new_html_bytes)
    _refresh_compliance_notice_hash(compliance_manifest, new_html_bytes)
    verify_owned_webkit_notices(app, runtime_frameworks, project_root=project_root,
                                source_offer_root=source_offer_root)
    return {
        "runtimeLibrarySHA256": library_hash,
        "licenseSHA256": LICENSE_SHA256,
        "webcoreLGPL2SHA256": WEBCORE_LGPL2_SHA256,
        "webcoreLGPL21SHA256": WEBCORE_LGPL21_SHA256,
        "jscCopyingLibSHA256": JSC_COPYING_LIB_SHA256,
        "jscBinjaAttributionSHA256": JSC_BINJA_ATTRIBUTION_SHA256,
        "jscBinjaApacheSHA256": JSC_BINJA_APACHE_SHA256,
        "jscMPL11SHA256": JSC_MPL11_SHA256,
        "jscGPL2SHA256": JSC_GPL2_SHA256,
        "jscHeaderlessBSD2LicenseSHA256": JSC_HEADERLESS_BSD2_LICENSE_SHA256,
        "jscHeaderlessBSD2ReviewSHA256": jsc_bsd2_review_hash,
        "jscHeaderlessBSD2RuntimeSHA256": jsc_bsd2_image_hash,
        "jscGeneratedOutputHeaderSHA256": JSC_GENERATED_OUTPUT_HEADERS_SHA256,
        "jscGeneratedOutputManifestSHA256": JSC_GENERATED_OUTPUT_MANIFEST_SHA256,
        "jscUnicodeLicenseSHA256": JSC_UNICODE_LICENSE_SHA256,
        "jscGeneratedInputLineageSHA256": JSC_GENERATED_LINEAGE_SHA256,
        "angleRuntimeSHA256": angle_hash,
        "angleLicenseSHA256": ANGLE_LICENSE_SHA256,
        "xxhashLicenseSHA256": XXHASH_LICENSE_SHA256,
        "chromiumAngleLicenseSHA256": CHROMIUM_ANGLE_LICENSE_SHA256,
        "webrtcRuntimeSHA256": webrtc_hash,
        "webrtcManifestSHA256": WEBRTC_MANIFEST_SHA256,
        "webrtcNoticeCount": str(len(webrtc_notices)),
        "webCoreGeneratedInputHeaderSHA256": WEBCORE_GENERATED_HEADERS_SHA256,
        "webCorePopoverLicenseSHA256": WEBCORE_POPOVER_LICENSE_SHA256,
        "webCorePopoverReviewSHA256": webcore_popover_review_hash,
        "webCoreColorDataLicenseSHA256": WEBCORE_COLORDATA_LICENSE_SHA256,
        "webCoreColorDataReviewSHA256": webcore_colordata_review_hash,
        "webCoreCSSGeneratedAppleLicenseSHA256": WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256,
        "webCoreCSSGeneratedLGPL2LicenseSHA256": WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256,
        "webCoreCSSGeneratedReviewSHA256": webcore_css_review_hash,
        "webCoreMediaControlsRightsReviewSHA256": WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256,
        "webCoreMediaControlsReviewSHA256": webcore_media_review_hash,
        "webCoreModelIblLicenseSHA256": (
            WEBCORE_MODEL_IBL_LICENSE_SHA256 if webcore_model_ibl is not None else "not-present"),
        "webCoreModelIblAttributionSHA256": (
            WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256 if webcore_model_ibl is not None else "not-present"),
        "webCoreModelIblDiffuseRuntimeSHA256": (
            str(webcore_model_ibl["diffuseSHA256"]) if webcore_model_ibl is not None else "not-present"),
        "webCoreModelIblSpecularRuntimeSHA256": (
            str(webcore_model_ibl["specularSHA256"]) if webcore_model_ibl is not None else "not-present"),
        "webrtcGeneratedInputHeaderSHA256": WEBRTC_GENERATED_HEADERS_SHA256,
        "webInspectorExternalLicenseCount": str(len(WEBINSPECTOR_LICENSES)),
        "webInspectorFrameworkSourceNoticeSHA256": WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256,
        "webKitSandboxSourceNoticeCount": str(len(sandbox_rows)),
        "webKitSourceCandidateNoticeCount": str(len(source_candidate_sources)),
        "webKitSourceCandidateManifestSHA256": hashlib.sha256(source_candidate_manifest_bytes).hexdigest(),
        "webKitSwiftSourceHeaderNoticeCount": str(len(webkit_swift_sources)),
        "webKitSwiftSourceHeaderManifestSHA256": WEBKIT_SWIFT_MANIFEST_SHA256,
        "webKitXPCEntrypointNoticeCount": str(len(webkit_xpc_map["runtimeImages"])),
        "webgpuRuntimeSHA256": webgpu_hash,
        "webgpuLicenseSHA256": WEBGPU_LICENSE_SHA256,
    }


@_with_v382_runtime_hashes
def verify_owned_webkit_notices(
    app: Path, runtime_frameworks: Path | None = None, *, project_root: Path = PROJECT_ROOT,
    source_offer_root: Path | None = None,
) -> dict[str, str]:
    """Fail closed unless app notices and the packaged license match the runtime."""
    _validate_v135_runtime_binding_evidence(project_root)
    webgpu_license = _webgpu_license(project_root)
    webgpu_adapter_header = _webgpu_adapter_header(project_root)
    jsc_binja_attribution, jsc_binja_apache = _jsc_binja_license_sources(project_root)
    jsc_bsd2_license, jsc_bsd2_review_path, jsc_bsd2_review = (
        _jsc_headerless_bsd2_sources(project_root))
    jsc_bsd2_image_hash = None
    if runtime_frameworks is not None:
        _jsc_headerless_bsd2_image(runtime_frameworks, jsc_bsd2_review)
        jsc_bsd2_image_hash = _runtime_image_build_sha(
            runtime_frameworks, Path("JavaScriptCore.framework/Versions/A/JavaScriptCore"),
            jsc_bsd2_review["sourceBinding"]["runtimeImageSHA256"])
    jsc_generated_output_manifest_path, jsc_generated_output_headers_path, jsc_generated_output_manifest = (
        _jsc_generated_output_notices(project_root, runtime_frameworks))
    jsc_copying_lib = _jsc_copying_lib_license(project_root)
    jsc_bsd2_review_hash = sha256_file(jsc_bsd2_review_path)
    source_license = _license(project_root)
    source_lgpl2 = _webcore_lgpl2_license(project_root)
    source_lgpl21 = _webcore_lgpl21_license(project_root)
    jsc_tri_license_sources = _jsc_tri_license_texts(project_root)
    jsc_unicode_license, jsc_lineage = _jsc_unicode_sources(project_root)
    angle_notice_sources = _angle_notice_sources(project_root)
    webrtc_manifest, webrtc_notices = _webrtc_notice_sources(project_root)
    source_webrtc_mpl2 = _webrtc_mpl2_license(project_root)
    source_libwebm_authors = _webrtc_libwebm_authors(project_root)
    source_dav1d_headers = _dav1d_headers(project_root)
    source_rnnoise_header = _rnnoise_header(project_root)
    source_libsrtp_headers = _libsrtp_headers(project_root)
    source_opus_headers = _opus_headers(project_root)
    linked_headers_manifest, linked_header_sources = _linked_source_header_notices(project_root)
    webcore_popover_license, webcore_popover_review = _webcore_popover_notice_sources(
        project_root, linked_headers_manifest)
    webcore_popover_review_hash = sha256_file(webcore_popover_review)
    webcore_colordata_license, webcore_colordata_review = _webcore_colordata_notice_sources(
        project_root, linked_headers_manifest)
    webcore_colordata_review_hash = sha256_file(webcore_colordata_review)
    webcore_css_apple_license, webcore_css_lgpl2_license, webcore_css_review = (
        _webcore_css_generated_notice_sources(project_root, linked_headers_manifest))
    webcore_css_review_hash = sha256_file(webcore_css_review)
    webcore_media_review = _webcore_media_controls_notice_sources(project_root)
    webcore_media_review_hash = sha256_file(webcore_media_review)
    webcore_media_overlay = _webcore_media_controls_overlay(
        project_root, runtime_frameworks, source_offer_root)
    webcore_model_ibl = _webcore_model_ibl_notice_sources(project_root, runtime_frameworks)
    ircam_listen_hrtf = _ircam_listen_hrtf_notice(project_root, runtime_frameworks)
    webcore_first_party = _webcore_first_party_resource_overlays(runtime_frameworks, source_offer_root)
    webkit_warning_colors = _webkit_warning_colors_overlay(runtime_frameworks, source_offer_root)
    webcore_generated_headers = _physical_path_beneath(
        project_root, WEBCORE_GENERATED_HEADERS_SOURCE,
        label="pinned WebCore generated-input headers")
    if sha256_file(webcore_generated_headers) != WEBCORE_GENERATED_HEADERS_SHA256:
        raise NoticeError("pinned WebCore generated-input headers SHA-256 mismatch")
    webrtc_generated_headers = _physical_path_beneath(
        project_root, WEBRTC_GENERATED_HEADERS_SOURCE,
        label="pinned libwebrtc generated-input headers")
    if sha256_file(webrtc_generated_headers) != WEBRTC_GENERATED_HEADERS_SHA256:
        raise NoticeError("pinned libwebrtc generated-input headers SHA-256 mismatch")
    _webinspector_notice_sources(project_root, runtime_frameworks)
    sandbox_rows = _sandbox_notice_sources(project_root)
    source_candidate_manifest, source_candidate_manifest_bytes, source_candidate_sources = (
        _source_candidate_notice_sources(project_root, source_offer_root, runtime_frameworks))
    webkit_swift_manifest, webkit_swift_manifest_bytes, webkit_swift_sources = (
        _webkit_swift_source_notice_sources(project_root))
    if runtime_frameworks is not None:
        _verify_webkit_swift_runtime_images(runtime_frameworks, webkit_swift_manifest)
    markdown = _safe_destination(app, NOTICE_DESTINATION, create_parent=False)
    html_notice = _safe_destination(app, HTML_DESTINATION, create_parent=False)
    packaged_license = _safe_destination(app, LICENSE_DESTINATION, create_parent=False)
    packaged_webgpu_license = _safe_destination(
        app, WEBGPU_LICENSE_DESTINATION, create_parent=False)
    packaged_webgpu_adapter_header = _safe_destination(app, WEBGPU_ADAPTER_HEADER_DESTINATION, create_parent=False)
    packaged_jsc_bsd2_license = _safe_destination(
        app, JSC_HEADERLESS_BSD2_LICENSE_DESTINATION, create_parent=False)
    packaged_jsc_bsd2_review = _safe_destination(
        app, JSC_HEADERLESS_BSD2_REVIEW_DESTINATION, create_parent=False)
    packaged_webinspector_framework_license = _safe_destination(
        app, WEBINSPECTOR_FRAMEWORK_LICENSE_DESTINATION, create_parent=False)
    packaged_lgpl2 = _safe_destination(app, WEBCORE_LGPL2_DESTINATION, create_parent=False)
    packaged_lgpl21 = _safe_destination(app, WEBCORE_LGPL21_DESTINATION, create_parent=False)
    packaged_jsc_copying_lib = _safe_destination(
        app, JSC_COPYING_LIB_DESTINATION, create_parent=False)
    packaged_jsc_binja_attribution = _safe_destination(
        app, JSC_BINJA_ATTRIBUTION_DESTINATION, create_parent=False)
    packaged_jsc_binja_apache = _safe_destination(
        app, JSC_BINJA_APACHE_DESTINATION, create_parent=False)
    packaged_jsc_tri_licenses = [
        _safe_destination(app, destination, create_parent=False)
        for _source, _digest, destination in jsc_tri_license_sources
    ]
    packaged_jsc_unicode_license = _safe_destination(
        app, JSC_UNICODE_LICENSE_DESTINATION, create_parent=False)
    packaged_jsc_lineage = _safe_destination(
        app, JSC_GENERATED_LINEAGE_DESTINATION, create_parent=False)
    packaged_jsc_generated_output_manifest = _safe_destination(
        app, JSC_GENERATED_OUTPUT_DESTINATION_ROOT / "Manifest.json", create_parent=False)
    packaged_jsc_generated_output_headers = _safe_destination(
        app, JSC_GENERATED_OUTPUT_DESTINATION_ROOT / "GeneratedOutputHeaders.txt", create_parent=False)
    packaged_angle_licenses = [
        _safe_destination(app, destination, create_parent=False)
        for _source, _name, _expected_hash, destination in angle_notice_sources
    ]
    packaged_webrtc_manifest = _safe_destination(
        app, WEBRTC_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_webrtc_mpl2 = _safe_destination(
        app, WEBRTC_MPL2_DESTINATION, create_parent=False)
    packaged_linked_headers_manifest = _safe_destination(
        app, LINKED_HEADERS_DESTINATION_ROOT / "MANIFEST.json", create_parent=False)
    packaged_linked_headers = [
        _safe_destination(app, LINKED_HEADERS_DESTINATION_ROOT / row["noticePath"],
                          create_parent=False)
        for row in linked_headers_manifest["images"]
    ]
    packaged_webcore_generated_headers = _safe_destination(
        app, WEBCORE_GENERATED_HEADERS_DESTINATION, create_parent=False)
    packaged_webcore_popover_license = _safe_destination(
        app, WEBCORE_POPOVER_LICENSE_DESTINATION, create_parent=False)
    packaged_webcore_popover_review = _safe_destination(
        app, WEBCORE_POPOVER_REVIEW_DESTINATION, create_parent=False)
    packaged_webcore_colordata_license = _safe_destination(
        app, WEBCORE_COLORDATA_LICENSE_DESTINATION, create_parent=False)
    packaged_webcore_colordata_review = _safe_destination(
        app, WEBCORE_COLORDATA_REVIEW_DESTINATION, create_parent=False)
    packaged_webcore_css_apple_license = _safe_destination(
        app, WEBCORE_CSS_GENERATED_APPLE_LICENSE_DESTINATION, create_parent=False)
    packaged_webcore_css_review = _safe_destination(
        app, WEBCORE_CSS_GENERATED_REVIEW_DESTINATION, create_parent=False)
    packaged_webcore_media_review = _safe_destination(
        app, WEBCORE_MEDIA_CONTROLS_REVIEW_DESTINATION, create_parent=False)
    packaged_webcore_media_overlay_license = (
        _safe_destination(app, WEBCORE_MEDIA_CONTROLS_OVERLAY_LICENSE_DESTINATION, create_parent=False)
        if webcore_media_overlay is not None else None)
    packaged_webcore_media_overlay_attribution = (
        _safe_destination(app, WEBCORE_MEDIA_CONTROLS_OVERLAY_ATTRIBUTION_DESTINATION, create_parent=False)
        if webcore_media_overlay is not None else None)
    packaged_webcore_model_ibl_license = (
        _safe_destination(app, WEBCORE_MODEL_IBL_LICENSE_DESTINATION, create_parent=False)
        if webcore_model_ibl is not None else None)
    packaged_webcore_model_ibl_attribution = (
        _safe_destination(app, WEBCORE_MODEL_IBL_ATTRIBUTION_DESTINATION, create_parent=False)
        if webcore_model_ibl is not None else None)
    packaged_ircam_listen_hrtf_notice = _safe_destination(
        app, IRCAM_LISTEN_HRTF_NOTICE_DESTINATION, create_parent=False)
    packaged_webcore_first_party = ([
        (_safe_destination(app, WEBCORE_FIRST_PARTY_NOTICE_ROOT / str(row["name"]) / "LICENSE.txt", create_parent=False),
         _safe_destination(app, WEBCORE_FIRST_PARTY_NOTICE_ROOT / str(row["name"]) / "ATTRIBUTION.json", create_parent=False))
        for row in webcore_first_party] if webcore_first_party is not None else [])
    packaged_webkit_warning_colors = (
        (_safe_destination(app, WEBKIT_WARNING_COLOR_NOTICE_ROOT / str(webkit_warning_colors["name"]) / "LICENSE.txt", create_parent=False),
         _safe_destination(app, WEBKIT_WARNING_COLOR_NOTICE_ROOT / str(webkit_warning_colors["name"]) / "ATTRIBUTION.json", create_parent=False))
        if webkit_warning_colors is not None else None)
    packaged_webrtc_generated_headers = _safe_destination(
        app, WEBRTC_GENERATED_HEADERS_DESTINATION, create_parent=False)
    packaged_webrtc_notices = [
        _safe_destination(app, WEBRTC_NOTICE_ROOT / output_relative, create_parent=False)
        for _source_relative, output_relative, _digest, _size in webrtc_notices
    ]
    packaged_sandbox_manifest = _safe_destination(
        app, SANDBOX_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_sandbox_sources = [
        _safe_destination(app, SANDBOX_NOTICE_ROOT / name, create_parent=False)
        for name, _source_path, _runtime_path, _size in sandbox_rows
    ]
    packaged_source_candidate_manifest = _safe_destination(
        app, SOURCE_CANDIDATE_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_source_candidate_files = [
        _safe_destination(app, SOURCE_CANDIDATE_NOTICE_ROOT / row["outputPath"],
                          create_parent=False)
        for row in source_candidate_manifest["entries"]
    ]
    packaged_webkit_swift_manifest = _safe_destination(
        app, WEBKIT_SWIFT_NOTICE_ROOT / "MANIFEST.json", create_parent=False)
    packaged_webkit_swift_headers = [
        _safe_destination(app, WEBKIT_SWIFT_NOTICE_ROOT / row["outputPath"],
                          create_parent=False)
        for row in webkit_swift_manifest["entries"]
    ]
    if sha256_file(packaged_license) != LICENSE_SHA256:
        raise NoticeError("packaged Swift runtime license SHA-256 mismatch")
    if (sha256_file(packaged_webgpu_license) != WEBGPU_LICENSE_SHA256
            or packaged_webgpu_license.read_bytes() != webgpu_license.read_bytes()):
        raise NoticeError("packaged WebGPU BSD-2 license differs from pinned source text")
    _physical_file(packaged_webgpu_adapter_header, label="packaged WebGPU Adapter source header")
    if (sha256_file(packaged_webgpu_adapter_header) != WEBGPU_ADAPTER_HEADER_SHA256
            or packaged_webgpu_adapter_header.read_bytes() != webgpu_adapter_header.read_bytes()):
        raise NoticeError("packaged WebGPU Adapter source header differs from pinned source")
    if (sha256_file(packaged_jsc_bsd2_license) != JSC_HEADERLESS_BSD2_LICENSE_SHA256
            or packaged_jsc_bsd2_license.read_bytes() != jsc_bsd2_license.read_bytes()):
        raise NoticeError("packaged JavaScriptCore BSD-2 text differs from pinned source")
    if (sha256_file(packaged_jsc_bsd2_review) != JSC_HEADERLESS_BSD2_REVIEW_SHA256
            or packaged_jsc_bsd2_review.read_bytes() != jsc_bsd2_review_path.read_bytes()):
        raise NoticeError("packaged JavaScriptCore headerless-input review differs from pinned evidence")
    if (sha256_file(packaged_jsc_generated_output_manifest) != JSC_GENERATED_OUTPUT_MANIFEST_SHA256
            or packaged_jsc_generated_output_manifest.read_bytes()
            != jsc_generated_output_manifest_path.read_bytes()
            or sha256_file(packaged_jsc_generated_output_headers) != JSC_GENERATED_OUTPUT_HEADERS_SHA256
            or packaged_jsc_generated_output_headers.read_bytes()
            != jsc_generated_output_headers_path.read_bytes()):
        raise NoticeError("packaged JavaScriptCore generated-output headers differ from pinned evidence")
    if (sha256_file(packaged_ircam_listen_hrtf_notice) != IRCAM_LISTEN_HRTF_NOTICE_SHA256
            or packaged_ircam_listen_hrtf_notice.read_bytes()
            != ircam_listen_hrtf["notice"].read_bytes()):
        raise NoticeError("packaged IRCAM LISTEN permission notice differs from pinned evidence")
    if packaged_license.read_bytes() != source_license.read_bytes():
        raise NoticeError("packaged Swift runtime license differs from canonical license")
    framework_license_source = project_root / WEBINSPECTOR_FRAMEWORK_LICENSE_SOURCE
    if (sha256_file(packaged_webinspector_framework_license)
            != WEBINSPECTOR_FRAMEWORK_LICENSE_SHA256
            or packaged_webinspector_framework_license.read_bytes()
            != framework_license_source.read_bytes()):
        raise NoticeError("packaged WebInspectorUI framework source notice differs from pinned text")
    _webkit_xpc_notice_source, webkit_xpc_map, webkit_xpc_notice_bytes = (
        _webkit_xpc_entrypoint_notice(project_root))
    packaged_webkit_xpc_notice = _safe_destination(
        app, WEBKIT_XPC_ENTRYPOINT_NOTICE_DESTINATION, create_parent=False)
    if (sha256_file(packaged_webkit_xpc_notice) != WEBKIT_XPC_ENTRYPOINT_NOTICE_SHA256
            or packaged_webkit_xpc_notice.read_bytes() != webkit_xpc_notice_bytes):
        raise NoticeError("packaged WebKit XPC entrypoint notice differs from pinned text")
    if sha256_file(packaged_lgpl2) != WEBCORE_LGPL2_SHA256:
        raise NoticeError("packaged WebCore LGPL-2 license SHA-256 mismatch")
    if packaged_lgpl2.read_bytes() != source_lgpl2.read_bytes():
        raise NoticeError("packaged WebCore LGPL-2 license differs from pinned source text")
    if sha256_file(packaged_lgpl21) != WEBCORE_LGPL21_SHA256:
        raise NoticeError("packaged WebCore LGPL-2.1 license SHA-256 mismatch")
    if packaged_lgpl21.read_bytes() != source_lgpl21.read_bytes():
        raise NoticeError("packaged WebCore LGPL-2.1 license differs from pinned source text")
    if (sha256_file(packaged_jsc_copying_lib) != JSC_COPYING_LIB_SHA256
            or packaged_jsc_copying_lib.read_bytes() != jsc_copying_lib.read_bytes()):
        raise NoticeError("packaged JavaScriptCore COPYING.LIB differs from pinned source text")
    for packaged, source, expected, label in (
            (packaged_jsc_binja_attribution, jsc_binja_attribution,
             JSC_BINJA_ATTRIBUTION_SHA256, "Binary Ninja attribution"),
            (packaged_jsc_binja_apache, jsc_binja_apache,
             JSC_BINJA_APACHE_SHA256, "Binary Ninja Apache license")):
        if sha256_file(packaged) != expected or packaged.read_bytes() != source.read_bytes():
            raise NoticeError(f"packaged JavaScriptCore {label} differs from pinned source text")
    for (source, expected_hash, _destination), packaged in zip(
            jsc_tri_license_sources, packaged_jsc_tri_licenses):
        if (sha256_file(packaged) != expected_hash
                or packaged.read_bytes() != source.read_bytes()):
            raise NoticeError(f"packaged JavaScriptCore license differs from pinned source: {source.name}")
    if (sha256_file(packaged_jsc_unicode_license) != JSC_UNICODE_LICENSE_SHA256
            or packaged_jsc_unicode_license.read_bytes() != jsc_unicode_license.read_bytes()):
        raise NoticeError("packaged Unicode License v3 differs from pinned source")
    if (sha256_file(packaged_jsc_lineage) != JSC_GENERATED_LINEAGE_SHA256
            or packaged_jsc_lineage.read_bytes() != jsc_lineage.read_bytes()):
        raise NoticeError("packaged JavaScriptCore generated-input lineage differs from pinned evidence")
    for (source_relative, name, expected_hash, _destination), packaged in zip(
            angle_notice_sources, packaged_angle_licenses):
        source = project_root / source_relative
        if sha256_file(packaged) != expected_hash:
            raise NoticeError(f"packaged WebKit license SHA-256 mismatch: {name}")
        if packaged.read_bytes() != source.read_bytes():
            raise NoticeError(f"packaged WebKit license differs from pinned source: {name}")
    if (sha256_file(packaged_webrtc_manifest) != WEBRTC_MANIFEST_SHA256
            or packaged_webrtc_manifest.read_bytes()
            != (project_root / WEBRTC_MANIFEST_SOURCE).read_bytes()):
        raise NoticeError("packaged WebRTC candidate manifest differs from pinned manifest")
    if (sha256_file(packaged_webrtc_mpl2) != WEBRTC_MPL2_SHA256
            or packaged_webrtc_mpl2.read_bytes() != source_webrtc_mpl2.read_bytes()):
        raise NoticeError("packaged WebRTC shim MPL-2.0 text differs from pinned source")
    _verify_packaged_libwebm_authors(app, source_libwebm_authors)
    _verify_packaged_dav1d_headers(app, source_dav1d_headers)
    _verify_packaged_rnnoise_header(app, source_rnnoise_header)
    _verify_packaged_libsrtp_headers(app, source_libsrtp_headers)
    _verify_packaged_opus_headers(app, source_opus_headers)
    if (sha256_file(packaged_linked_headers_manifest) != LINKED_HEADERS_MANIFEST_SHA256
            or packaged_linked_headers_manifest.read_bytes()
            != (project_root / LINKED_HEADERS_MANIFEST_SOURCE).read_bytes()):
        raise NoticeError("packaged linked source-header manifest differs from pinned source")
    for (source, digest, size), packaged in zip(linked_header_sources, packaged_linked_headers):
        if (packaged.stat().st_size != size or sha256_file(packaged) != digest
                or packaged.read_bytes() != source.read_bytes()):
            raise NoticeError("packaged linked source-header notice differs from pinned source")
    if (sha256_file(packaged_webcore_generated_headers) != WEBCORE_GENERATED_HEADERS_SHA256
            or packaged_webcore_generated_headers.read_bytes() != webcore_generated_headers.read_bytes()):
        raise NoticeError("packaged WebCore generated-input headers differ from pinned source")
    if (sha256_file(packaged_webcore_popover_license) != WEBCORE_POPOVER_LICENSE_SHA256
            or packaged_webcore_popover_license.read_bytes() != webcore_popover_license.read_bytes()):
        raise NoticeError("packaged WebCore popover BSD-2 text differs from pinned source")
    if (sha256_file(packaged_webcore_popover_review) != WEBCORE_POPOVER_REVIEW_SHA256
            or packaged_webcore_popover_review.read_bytes() != webcore_popover_review.read_bytes()):
        raise NoticeError("packaged WebCore popover review differs from pinned source")
    if (sha256_file(packaged_webcore_colordata_license) != WEBCORE_COLORDATA_LICENSE_SHA256
            or packaged_webcore_colordata_license.read_bytes() != webcore_colordata_license.read_bytes()):
        raise NoticeError("packaged WebCore ColorData BSD-2 text differs from pinned source")
    if (sha256_file(packaged_webcore_colordata_review) != WEBCORE_COLORDATA_REVIEW_SHA256
            or packaged_webcore_colordata_review.read_bytes() != webcore_colordata_review.read_bytes()):
        raise NoticeError("packaged WebCore ColorData review differs from pinned source")
    if (sha256_file(packaged_webcore_css_apple_license) != WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256
            or packaged_webcore_css_apple_license.read_bytes() != webcore_css_apple_license.read_bytes()):
        raise NoticeError("packaged WebCore Apple BSD-2 text differs from pinned source")
    if (WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256 != WEBCORE_LGPL2_SHA256
            or webcore_css_lgpl2_license.read_bytes() != _webcore_lgpl2_license(project_root).read_bytes()):
        raise NoticeError("pinned WebCore LGPL-2 text differs from the established source notice")
    if (sha256_file(packaged_webcore_css_review) != WEBCORE_CSS_GENERATED_REVIEW_SHA256
            or packaged_webcore_css_review.read_bytes() != webcore_css_review.read_bytes()):
        raise NoticeError("packaged WebCore generated CSS review differs from pinned source")
    if (sha256_file(packaged_webcore_media_review) != WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256
            or packaged_webcore_media_review.read_bytes() != webcore_media_review.read_bytes()):
        raise NoticeError("packaged WebCore media-controls asset review differs from pinned source")
    if webcore_media_overlay is not None:
        assert packaged_webcore_media_overlay_license is not None
        assert packaged_webcore_media_overlay_attribution is not None
        if (sha256_file(packaged_webcore_media_overlay_license) != webcore_media_overlay["licenseSHA256"]
                or packaged_webcore_media_overlay_license.read_bytes() != webcore_media_overlay["license"].read_bytes()
                or sha256_file(packaged_webcore_media_overlay_attribution) != webcore_media_overlay["attributionSHA256"]
                or packaged_webcore_media_overlay_attribution.read_bytes() != webcore_media_overlay["attribution"].read_bytes()):
            raise NoticeError("packaged first-party media-controls BSD-2 license or attribution differs")
    elif ((app / WEBCORE_MEDIA_CONTROLS_OVERLAY_LICENSE_DESTINATION).exists()
          or (app / WEBCORE_MEDIA_CONTROLS_OVERLAY_ATTRIBUTION_DESTINATION).exists()):
        raise NoticeError("media-controls overlay notice exists without source-offer and runtime binding")
    if webcore_model_ibl is not None:
        assert packaged_webcore_model_ibl_license is not None
        assert packaged_webcore_model_ibl_attribution is not None
        for packaged, source, digest, label in (
                (packaged_webcore_model_ibl_license, webcore_model_ibl["license"],
                 WEBCORE_MODEL_IBL_LICENSE_SHA256, "license"),
                (packaged_webcore_model_ibl_attribution, webcore_model_ibl["attribution"],
                 WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256, "attribution")):
            if sha256_file(packaged) != digest or packaged.read_bytes() != source.read_bytes():
                raise NoticeError(f"packaged WebModel {label} differs from pinned source")
    elif ((app / WEBCORE_MODEL_IBL_LICENSE_DESTINATION).exists()
          or (app / WEBCORE_MODEL_IBL_ATTRIBUTION_DESTINATION).exists()):
        raise NoticeError("WebModel license files exist without exact replacement runtime bytes")
    if webcore_first_party is not None:
        expected_first_party_paths: set[str] = set()
        for row, (license_path, attribution_path) in zip(webcore_first_party, packaged_webcore_first_party):
            expected_first_party_paths.update((license_path.relative_to(app).as_posix(),
                                               attribution_path.relative_to(app).as_posix()))
            for packaged, source, digest in (
                    (license_path, row["license"], row["licenseSHA256"]),
                    (attribution_path, row["attribution"], row["attributionSHA256"])):
                if sha256_file(packaged) != digest or packaged.read_bytes() != source.read_bytes():
                    raise NoticeError(f"packaged first-party WebCore notice differs: {packaged.name}")
        first_party_root = app / WEBCORE_FIRST_PARTY_NOTICE_ROOT
        actual_first_party_paths = {
            path.relative_to(app).as_posix() for path in first_party_root.rglob("*")
            if path.is_file() or path.is_symlink()
        } if first_party_root.exists() else set()
        if actual_first_party_paths != expected_first_party_paths:
            raise NoticeError("packaged first-party WebCore notice directory has unexpected files")
    elif (app / WEBCORE_FIRST_PARTY_NOTICE_ROOT).exists():
        raise NoticeError("first-party WebCore notices exist without source-offer and runtime binding")
    if webkit_warning_colors is not None:
        assert packaged_webkit_warning_colors is not None
        expected_warning_paths = {
            path.relative_to(app).as_posix() for path in packaged_webkit_warning_colors
        }
        for packaged, source, digest in (
                (packaged_webkit_warning_colors[0], webkit_warning_colors["license"], webkit_warning_colors["licenseSHA256"]),
                (packaged_webkit_warning_colors[1], webkit_warning_colors["attribution"], webkit_warning_colors["attributionSHA256"])):
            if sha256_file(packaged) != digest or packaged.read_bytes() != source.read_bytes():
                raise NoticeError("packaged WebKit warning-color BSD-2 license or attribution differs")
        warning_root = app / WEBKIT_WARNING_COLOR_NOTICE_ROOT
        actual_warning_paths = {
            path.relative_to(app).as_posix() for path in warning_root.rglob("*")
            if path.is_file() or path.is_symlink()
        } if warning_root.exists() else set()
        if actual_warning_paths != expected_warning_paths:
            raise NoticeError("packaged WebKit warning-color notice directory has unexpected files")
    elif (app / WEBKIT_WARNING_COLOR_NOTICE_ROOT).exists():
        raise NoticeError("WebKit warning-color notices exist without source-offer and compiled runtime binding")
    if (sha256_file(packaged_webrtc_generated_headers) != WEBRTC_GENERATED_HEADERS_SHA256
            or packaged_webrtc_generated_headers.read_bytes() != webrtc_generated_headers.read_bytes()):
        raise NoticeError("packaged libwebrtc generated-input headers differ from pinned source")
    for (_source_relative, output_relative, digest, size), packaged in zip(
            webrtc_notices, packaged_webrtc_notices):
        if packaged.stat().st_size != size or sha256_file(packaged) != digest:
            raise NoticeError(f"packaged WebRTC notice hash/size mismatch: {output_relative}")
    canonical_sandbox_manifest = project_root / SANDBOX_SOURCE_ROOT / "MANIFEST.json"
    if (sha256_file(packaged_sandbox_manifest) != SANDBOX_MANIFEST_SHA256
            or packaged_sandbox_manifest.read_bytes() != canonical_sandbox_manifest.read_bytes()):
        raise NoticeError("packaged WebKit sandbox manifest differs from pinned source")
    for (name, _source_path, _runtime_path, size), packaged in zip(
            sandbox_rows, packaged_sandbox_sources):
        source = project_root / SANDBOX_SOURCE_ROOT / name
        if packaged.stat().st_size != size or packaged.read_bytes() != source.read_bytes():
            raise NoticeError(f"packaged WebKit sandbox source differs from pinned source: {name}")
    if (sha256_file(packaged_source_candidate_manifest) != hashlib.sha256(source_candidate_manifest_bytes).hexdigest()
            or packaged_source_candidate_manifest.read_bytes() != source_candidate_manifest_bytes):
        raise NoticeError("packaged WebKit source-candidate manifest differs from pinned evidence")
    for (source_path, source, expected_hash, expected_size), packaged in zip(
            source_candidate_sources, packaged_source_candidate_files):
        if (packaged.stat().st_size != expected_size or sha256_file(packaged) != expected_hash
                or packaged.read_bytes() != source.read_bytes()):
            raise NoticeError(f"packaged WebKit source license candidate differs: {source_path}")
    if (sha256_file(packaged_webkit_swift_manifest) != WEBKIT_SWIFT_MANIFEST_SHA256
            or packaged_webkit_swift_manifest.read_bytes() != webkit_swift_manifest_bytes):
        raise NoticeError("packaged WebKitSwift source-header manifest differs from pinned evidence")
    for (source_path, source, expected_hash, expected_size), packaged in zip(
            webkit_swift_sources, packaged_webkit_swift_headers):
        if (packaged.stat().st_size != expected_size or sha256_file(packaged) != expected_hash
                or packaged.read_bytes() != source.read_bytes()):
            raise NoticeError(f"packaged WebKitSwift source header differs: {source_path}")
    source_candidate_root = app / SOURCE_CANDIDATE_NOTICE_ROOT
    expected_source_candidate_paths = {
        "MANIFEST.json", *("files/" + row["sourcePath"] for row in source_candidate_manifest["entries"])
    }
    actual_source_candidate_paths = {
        path.relative_to(source_candidate_root).as_posix()
        for path in source_candidate_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual_source_candidate_paths != expected_source_candidate_paths:
        raise NoticeError("packaged WebKit source-candidate directory has unexpected files")
    webkit_swift_root = app / WEBKIT_SWIFT_NOTICE_ROOT
    expected_webkit_swift_paths = {
        "MANIFEST.json", *(row["outputPath"] for row in webkit_swift_manifest["entries"])
    }
    actual_webkit_swift_paths = {
        path.relative_to(webkit_swift_root).as_posix()
        for path in webkit_swift_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual_webkit_swift_paths != expected_webkit_swift_paths:
        raise NoticeError("packaged WebKitSwift source-header directory has unexpected files")
    markdown_text = markdown.read_text(encoding="utf-8")
    html_text = html_notice.read_text(encoding="utf-8")
    if (markdown_text.count(SECTION_MARKER) != 1 or html_text.count(HTML_MARKER) != 1
            or markdown_text.splitlines().count(LGPL2_SECTION_MARKER) != 1
            or html_text.count(LGPL2_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_COPYING_LIB_SECTION_MARKER) != 1
            or html_text.count(JSC_COPYING_LIB_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_BINJA_SECTION_MARKER) != 1
            or html_text.count(JSC_BINJA_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_BINJA_SECTION_MARKER) != 1
            or html_text.count(JSC_BINJA_HTML_MARKER) != 1
            or markdown_text.splitlines().count(LGPL21_SECTION_MARKER) != 1
            or html_text.count(LGPL21_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_TRI_LICENSE_SECTION_MARKER) != 1
            or html_text.count(JSC_TRI_LICENSE_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_HEADERLESS_BSD2_SECTION_MARKER) != 1
            or html_text.count(JSC_HEADERLESS_BSD2_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_GENERATED_OUTPUT_SECTION_MARKER) != 1
            or html_text.count(JSC_GENERATED_OUTPUT_HTML_MARKER) != 1
            or markdown_text.splitlines().count(JSC_UNICODE_SECTION_MARKER) != 1
            or html_text.count(JSC_UNICODE_HTML_MARKER) != 1
            or markdown_text.count(ANGLE_SECTION_MARKER) != 1
            or html_text.count(ANGLE_HTML_MARKER) != 1
            or markdown_text.count(WEBRTC_SECTION_MARKER) != 1
            or html_text.count(WEBRTC_HTML_MARKER) != 1
            or markdown_text.count(LINKED_HEADERS_SECTION_MARKER) != 1
            or html_text.count(LINKED_HEADERS_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_GENERATED_HEADERS_SECTION_MARKER) != 1
            or html_text.count(WEBCORE_GENERATED_HEADERS_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_POPOVER_SECTION_MARKER) != 1
            or html_text.count(WEBCORE_POPOVER_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_COLORDATA_SECTION_MARKER) != 1
            or html_text.count(WEBCORE_COLORDATA_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_CSS_GENERATED_SECTION_MARKER) != 1
            or html_text.count(WEBCORE_CSS_GENERATED_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_MEDIA_CONTROLS_SECTION_MARKER) != 1
            or html_text.count(WEBCORE_MEDIA_CONTROLS_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_MODEL_IBL_SECTION_MARKER) != (1 if webcore_model_ibl is not None else 0)
            or html_text.count(WEBCORE_MODEL_IBL_HTML_MARKER) != (1 if webcore_model_ibl is not None else 0)
            or markdown_text.count(IRCAM_LISTEN_HRTF_SECTION_MARKER) != 1
            or html_text.count(IRCAM_LISTEN_HRTF_HTML_MARKER) != 1
            or markdown_text.count(WEBCORE_FIRST_PARTY_SECTION_MARKER) != (1 if webcore_first_party else 0)
            or html_text.count(WEBCORE_FIRST_PARTY_HTML_MARKER) != (1 if webcore_first_party else 0)
            or markdown_text.count(WEBKIT_WARNING_COLOR_SECTION_MARKER) != (1 if webkit_warning_colors is not None else 0)
            or html_text.count(WEBKIT_WARNING_COLOR_HTML_MARKER) != (1 if webkit_warning_colors is not None else 0)
            or markdown_text.count(WEBRTC_GENERATED_HEADERS_SECTION_MARKER) != 1
            or html_text.count(WEBRTC_GENERATED_HEADERS_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBINSPECTOR_SECTION_MARKER) != 1
            or html_text.count(WEBINSPECTOR_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBINSPECTOR_FRAMEWORK_SECTION_MARKER) != 1
            or html_text.count(WEBINSPECTOR_FRAMEWORK_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBKIT_XPC_ENTRYPOINT_SECTION_MARKER) != 1
            or html_text.count(WEBKIT_XPC_ENTRYPOINT_HTML_MARKER) != 1
            or markdown_text.splitlines().count(SANDBOX_SECTION_MARKER) != 1
            or html_text.count(SANDBOX_HTML_MARKER) != 1
            or markdown_text.splitlines().count(SOURCE_CANDIDATE_SECTION_MARKER) != 1
            or html_text.count(SOURCE_CANDIDATE_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBKIT_SWIFT_SECTION_MARKER) != 1
            or html_text.count(WEBKIT_SWIFT_HTML_MARKER) != 1
            or markdown_text.splitlines().count(WEBGPU_SECTION_MARKER) != 1
            or html_text.count(WEBGPU_HTML_MARKER) != 1):
        raise NoticeError("owned-WebKit runtime notice is missing or duplicated")
    if (render_lgpl2_markdown().rstrip() not in markdown_text
            or render_lgpl2_html() not in html_text
            or render_lgpl21_markdown().rstrip() not in markdown_text
            or render_lgpl21_html() not in html_text):
        raise NoticeError("WebKit LGPL notice does not match pinned license text")
    if (render_jsc_copying_lib_markdown().rstrip() not in markdown_text
            or render_jsc_copying_lib_html() not in html_text):
        raise NoticeError("JavaScriptCore COPYING.LIB notice differs from pinned source evidence")
    if (render_jsc_binja_markdown().rstrip() not in markdown_text
            or render_jsc_binja_html() not in html_text):
        raise NoticeError("JavaScriptCore Binary Ninja notice differs from pinned source evidence")
    if (render_jsc_binja_markdown().rstrip() not in markdown_text
            or render_jsc_binja_html() not in html_text):
        raise NoticeError("JavaScriptCore Binary Ninja notice differs from pinned source evidence")
    if (render_jsc_tri_license_markdown().rstrip() not in markdown_text
            or render_jsc_tri_license_html() not in html_text):
        raise NoticeError("JavaScriptCore source-stated license alternative notice mismatch")
    expected_jsc_bsd2_image_hash = (
        jsc_bsd2_image_hash or jsc_bsd2_review["sourceBinding"]["runtimeImageSHA256"])
    if (render_jsc_headerless_bsd2_markdown(
            expected_jsc_bsd2_image_hash, jsc_bsd2_review_hash).rstrip() not in markdown_text
            or render_jsc_headerless_bsd2_html(
                expected_jsc_bsd2_image_hash, jsc_bsd2_review_hash) not in html_text):
        raise NoticeError("JavaScriptCore headerless-input BSD-2 notice differs from pinned evidence")
    if (render_jsc_generated_output_markdown(jsc_generated_output_manifest).rstrip() not in markdown_text
            or render_jsc_generated_output_html(jsc_generated_output_manifest) not in html_text):
        raise NoticeError("JavaScriptCore generated-output header notice differs from pinned evidence")
    if (render_jsc_unicode_markdown().rstrip() not in markdown_text
            or render_jsc_unicode_html() not in html_text):
        raise NoticeError("JavaScriptCore Unicode CaseFolding notice mismatch")
    if (render_webinspector_markdown().rstrip() not in markdown_text
            or render_webinspector_html() not in html_text):
        raise NoticeError("WebInspectorUI resource index differs from pinned license texts")
    if (render_webinspector_framework_markdown().rstrip() not in markdown_text
            or render_webinspector_framework_html() not in html_text):
        raise NoticeError("WebInspectorUI framework source notice differs from pinned text")
    if (render_webkit_xpc_entrypoint_markdown(webkit_xpc_map).rstrip() not in markdown_text
            or render_webkit_xpc_entrypoint_html(webkit_xpc_map) not in html_text):
        raise NoticeError("WebKit XPC entrypoint notice differs from pinned source map")
    if (render_sandbox_markdown(sandbox_rows).rstrip() not in markdown_text
            or render_sandbox_html(sandbox_rows) not in html_text):
        raise NoticeError("WebKit sandbox notice index differs from pinned source")
    if (render_source_candidate_markdown(source_candidate_manifest).rstrip() not in markdown_text
            or render_source_candidate_html(source_candidate_manifest) not in html_text):
        raise NoticeError("WebKit source-candidate notice differs from pinned crosswalk")
    if (render_webkit_swift_source_markdown(webkit_swift_manifest, webkit_swift_sources).rstrip()
            not in markdown_text
            or render_webkit_swift_source_html(webkit_swift_manifest, webkit_swift_sources)
            not in html_text):
        raise NoticeError("WebKitSwift source-header notice differs from pinned evidence")
    if (render_linked_headers_markdown(linked_headers_manifest).rstrip() not in markdown_text
            or render_linked_headers_html(linked_headers_manifest) not in html_text):
        raise NoticeError("linked source-header notice index differs from pinned evidence")
    if (render_webcore_generated_headers_markdown().rstrip() not in markdown_text
            or render_webcore_generated_headers_html() not in html_text):
        raise NoticeError("WebCore generated-input header index differs from pinned evidence")
    if (render_webcore_popover_markdown(webcore_popover_review_hash).rstrip() not in markdown_text
            or render_webcore_popover_html(webcore_popover_review_hash) not in html_text):
        raise NoticeError("WebCore popover source notice differs from pinned evidence")
    if (render_webcore_colordata_markdown(webcore_colordata_review_hash).rstrip() not in markdown_text
            or render_webcore_colordata_html(webcore_colordata_review_hash) not in html_text):
        raise NoticeError("WebCore ColorData source notice differs from pinned evidence")
    if (render_webcore_css_generated_markdown(webcore_css_review_hash).rstrip() not in markdown_text
            or render_webcore_css_generated_html(webcore_css_review_hash) not in html_text):
        raise NoticeError("WebCore generated CSS notices differ from pinned evidence")
    if (render_webcore_media_controls_markdown(webcore_media_review_hash, webcore_media_overlay).rstrip()
            not in markdown_text
            or render_webcore_media_controls_html(webcore_media_review_hash, webcore_media_overlay) not in html_text):
        raise NoticeError("WebCore media-controls asset notice differs from pinned evidence")
    if webcore_model_ibl is not None:
        if (render_webcore_model_ibl_markdown(webcore_model_ibl).rstrip() not in markdown_text
                or render_webcore_model_ibl_html(webcore_model_ibl) not in html_text):
            raise NoticeError("WebCore WebModel notice differs from exact replacement resource bytes")
    elif (WEBCORE_MODEL_IBL_LICENSE_SHA256 in markdown_text
          or WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256 in markdown_text):
        raise NoticeError("WebModel notice claims replacement resources without exact runtime binding")
    if (render_ircam_listen_hrtf_markdown(ircam_listen_hrtf).rstrip() not in markdown_text
            or render_ircam_listen_hrtf_html(ircam_listen_hrtf) not in html_text):
        raise NoticeError("WebCore IRCAM LISTEN HRTF notice differs from pinned permission and runtime bytes")
    if (webcore_first_party_markdown := render_webcore_first_party_markdown(webcore_first_party)):
        if (webcore_first_party_markdown.rstrip() not in markdown_text
                or render_webcore_first_party_html(webcore_first_party) not in html_text):
            raise NoticeError("WebCore first-party replacement notices differ from exact runtime resources")
    if (warning_markdown := render_webkit_warning_color_markdown(webkit_warning_colors)):
        if (warning_markdown.rstrip() not in markdown_text
                or render_webkit_warning_color_html(webkit_warning_colors) not in html_text):
            raise NoticeError("WebKit warning-color notice differs from compiled Assets.car resources")
    if (render_webrtc_generated_headers_markdown().rstrip() not in markdown_text
            or render_webrtc_generated_headers_html() not in html_text):
        raise NoticeError("libwebrtc generated-input header index differs from pinned evidence")
    webgpu_hash = WEBGPU_IMAGE_SHA256
    if runtime_frameworks is not None:
        _webgpu_image(runtime_frameworks)
        webgpu_hash = _runtime_image_build_sha(
            runtime_frameworks, WEBGPU_IMAGE_PATH, WEBGPU_IMAGE_SHA256)
    if (render_webgpu_markdown(webgpu_hash).rstrip() not in markdown_text
            or render_webgpu_html(webgpu_hash) not in html_text):
        raise NoticeError("WebGPU runtime notice does not match pinned image or license")
    if runtime_frameworks is not None:
        webrtc_library = _webrtc_library(runtime_frameworks)
        webrtc_hash = _runtime_image_build_sha(
            runtime_frameworks,
            _runtime_relative_path(runtime_frameworks, webrtc_library), None)
        if render_webrtc_markdown(webrtc_hash, webrtc_manifest, webrtc_notices).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match WebRTC image or manifest")
        if render_webrtc_html(webrtc_hash, webrtc_manifest, webrtc_notices) not in html_text:
            raise NoticeError("WebKit HTML notice does not match WebRTC image or manifest")
    elif (WEBRTC_MANIFEST_SHA256 not in markdown_text
          or str(len(webrtc_notices)) not in markdown_text
          or any(digest not in markdown_text for _source, _output, digest, _size in webrtc_notices)):
        raise NoticeError("WebKit Markdown notice does not identify the pinned WebRTC candidate")
    if runtime_frameworks is not None:
        angle_library = _angle_library(runtime_frameworks)
        angle_hash = _runtime_image_build_sha(
            runtime_frameworks,
            _runtime_relative_path(runtime_frameworks, angle_library), None)
        if render_angle_markdown(angle_hash).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match ANGLE bytes")
        if render_angle_html(angle_hash) not in html_text:
            raise NoticeError("WebKit HTML notice does not match ANGLE bytes")
    if runtime_frameworks is not None:
        compatibility_library = _compatibility_span(runtime_frameworks)
        library_hash = _runtime_image_build_sha(
            runtime_frameworks,
            _runtime_relative_path(runtime_frameworks, compatibility_library), None)
        if render_markdown(library_hash).rstrip() not in markdown_text:
            raise NoticeError("WebKit Markdown notice does not match CompatibilitySpan bytes")
        if render_html(library_hash) not in html_text:
            raise NoticeError("WebKit HTML notice does not match CompatibilitySpan bytes")
    elif (LICENSE_NAME not in markdown_text or LICENSE_SHA256 not in markdown_text
          or WEBCORE_LGPL2_NAME not in markdown_text
          or WEBCORE_LGPL2_SHA256 not in markdown_text
          or WEBCORE_LGPL21_NAME not in markdown_text
          or WEBCORE_LGPL21_SHA256 not in markdown_text
          or ANGLE_LICENSE_NAME not in markdown_text
          or ANGLE_LICENSE_SHA256 not in markdown_text
          or XXHASH_LICENSE_NAME not in markdown_text
          or XXHASH_LICENSE_SHA256 not in markdown_text
          or CHROMIUM_ANGLE_LICENSE_NAME not in markdown_text
          or CHROMIUM_ANGLE_LICENSE_SHA256 not in markdown_text):
        raise NoticeError("WebKit Markdown notice does not identify the applicable license")
    return {"licenseSHA256": LICENSE_SHA256, "webcoreLGPL2SHA256": WEBCORE_LGPL2_SHA256,
            "webcoreLGPL21SHA256": WEBCORE_LGPL21_SHA256,
            "jscCopyingLibSHA256": JSC_COPYING_LIB_SHA256,
            "webCorePopoverLicenseSHA256": WEBCORE_POPOVER_LICENSE_SHA256,
            "webCorePopoverReviewSHA256": webcore_popover_review_hash,
            "webCoreColorDataLicenseSHA256": WEBCORE_COLORDATA_LICENSE_SHA256,
            "webCoreColorDataReviewSHA256": webcore_colordata_review_hash,
            "webCoreCSSGeneratedAppleLicenseSHA256": WEBCORE_CSS_GENERATED_APPLE_LICENSE_SHA256,
            "webCoreCSSGeneratedLGPL2LicenseSHA256": WEBCORE_CSS_GENERATED_LGPL2_LICENSE_SHA256,
            "webCoreCSSGeneratedReviewSHA256": webcore_css_review_hash,
            "webCoreMediaControlsRightsReviewSHA256": WEBCORE_MEDIA_CONTROLS_REVIEW_SHA256,
            "webCoreMediaControlsReviewSHA256": webcore_media_review_hash,
            "webCoreMediaControlsOverlayLicenseSHA256": (
                str(webcore_media_overlay["licenseSHA256"]) if webcore_media_overlay is not None else "not-present"),
            "webCoreMediaControlsOverlayAttributionSHA256": (
                str(webcore_media_overlay["attributionSHA256"]) if webcore_media_overlay is not None else "not-present"),
            "webCoreModelIblLicenseSHA256": (
                WEBCORE_MODEL_IBL_LICENSE_SHA256 if webcore_model_ibl is not None else "not-present"),
            "webCoreModelIblAttributionSHA256": (
                WEBCORE_MODEL_IBL_ATTRIBUTION_SHA256 if webcore_model_ibl is not None else "not-present"),
            "webCoreModelIblDiffuseRuntimeSHA256": (
                str(webcore_model_ibl["diffuseSHA256"]) if webcore_model_ibl is not None else "not-present"),
            "webCoreModelIblSpecularRuntimeSHA256": (
                str(webcore_model_ibl["specularSHA256"]) if webcore_model_ibl is not None else "not-present"),
            "jscMPL11SHA256": JSC_MPL11_SHA256,
            "jscGPL2SHA256": JSC_GPL2_SHA256,
            "jscHeaderlessBSD2LicenseSHA256": JSC_HEADERLESS_BSD2_LICENSE_SHA256,
            "jscHeaderlessBSD2ReviewSHA256": jsc_bsd2_review_hash,
            "jscHeaderlessBSD2RuntimeSHA256": expected_jsc_bsd2_image_hash,
            "jscUnicodeLicenseSHA256": JSC_UNICODE_LICENSE_SHA256,
            "jscGeneratedInputLineageSHA256": JSC_GENERATED_LINEAGE_SHA256,
            "webKitSourceCandidateNoticeCount": str(len(source_candidate_sources)),
            "webKitSourceCandidateManifestSHA256": hashlib.sha256(source_candidate_manifest_bytes).hexdigest(),
            "webKitSwiftSourceHeaderNoticeCount": str(len(webkit_swift_sources)),
            "webKitSwiftSourceHeaderManifestSHA256": WEBKIT_SWIFT_MANIFEST_SHA256,
            "webCoreGeneratedInputHeaderSHA256": WEBCORE_GENERATED_HEADERS_SHA256,
            "webrtcGeneratedInputHeaderSHA256": WEBRTC_GENERATED_HEADERS_SHA256,
            "webKitXPCEntrypointNoticeCount": str(len(webkit_xpc_map["runtimeImages"])),
            "webgpuRuntimeSHA256": webgpu_hash,
            "webgpuLicenseSHA256": WEBGPU_LICENSE_SHA256}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--install", action="store_true")
    mode.add_argument("--verify", action="store_true")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--runtime-frameworks", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--source-offer-root", type=Path)
    parser.add_argument("--source-offer-manifest-sha256")
    args = parser.parse_args()
    source_offer_root = args.source_offer_root
    if source_offer_root is None:
        configured_offer = os.environ.get("NEANTIK_WEBKIT_SOURCE_OFFER_ROOT")
        if configured_offer:
            source_offer_root = Path(configured_offer)
    try:
        if args.install:
            if args.runtime_frameworks is None:
                raise NoticeError("--runtime-frameworks is required for installation")
            result = install_owned_webkit_notices(
                args.app, args.runtime_frameworks, project_root=args.project_root,
                source_offer_root=source_offer_root,
                source_offer_manifest_sha256=args.source_offer_manifest_sha256)
        else:
            result = verify_owned_webkit_notices(
                args.app, args.runtime_frameworks, project_root=args.project_root,
                source_offer_root=source_offer_root,
                source_offer_manifest_sha256=args.source_offer_manifest_sha256)
    except (OSError, NoticeError) as error:
        print(f"WebKit runtime notice check failed: {error}", file=sys.stderr)
        return 1
    print("PASS: owned-WebKit runtime notices verified")
    print(f"License SHA-256: {result['licenseSHA256']}")
    print(f"WebCore LGPL-2 text SHA-256: {result['webcoreLGPL2SHA256']}")
    print(f"WebCore LGPL-2.1 text SHA-256: {result['webcoreLGPL21SHA256']}")
    if "angleRuntimeSHA256" in result:
        print(f"ANGLE image SHA-256: {result['angleRuntimeSHA256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
