import hashlib
import io
import tarfile
import unittest
from unittest.mock import patch
import chromium_15612_node_origin as module
from chromium_15612_generated_cache import M156CacheError


class NodeOriginTests(unittest.TestCase):
    def fixture(self, members=None):
        members = members or [('.', b'', tarfile.DIRTYPE), ('./pkg', b'', tarfile.DIRTYPE),
                              ('./pkg/package.json', b'{}', tarfile.REGTYPE)]
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            for name, raw, kind in members:
                entry = tarfile.TarInfo(name); entry.type = kind
                if kind == tarfile.SYMTYPE: entry.linkname = '../pkg'
                entry.size = len(raw) if kind == tarfile.REGTYPE else 0
                archive.addfile(entry, io.BytesIO(raw) if entry.size else None)
        return output.getvalue()

    def verify(self, raw=None, requested=None):
        data = raw if raw is not None else self.fixture()
        names = requested if requested is not None else {module.PREFIX+'pkg/package.json': module.sha(b'{}')}
        with patch.object(module, 'ARCHIVE_SIZE', len(data)), patch.object(module, 'ARCHIVE_SHA256', module.sha(data)):
            return module.verify_archive(io.BytesIO(data), names)

    def test_selected_origin_digest_and_truthful_scope(self):
        report = self.verify()
        self.assertEqual(report['selectedPayloadCount'], 1)
        self.assertFalse(report['archiveExtracted'])
        self.assertFalse(report['releaseReady'])
        self.assertTrue(report['finalLiveSourceBindingStillRequired'])

    def test_wrong_pristine_digest_and_missing_selected_member_refused(self):
        for requested in ({module.PREFIX+'pkg/package.json': 'f'*64},
                          {module.PREFIX+'pkg/missing': module.sha(b'{}')}):
            with self.subTest(requested=requested), self.assertRaises(M156CacheError): self.verify(requested=requested)

    def test_duplicate_alias_traversal_selected_link_and_parent_refused(self):
        variants = [[('.', b'', tarfile.DIRTYPE), ('./pkg', b'', tarfile.DIRTYPE),
                     ('pkg/package.json', b'{}', tarfile.REGTYPE), ('./pkg/package.json', b'{}', tarfile.REGTYPE)],
                    [('../outside', b'{}', tarfile.REGTYPE)],
                    [('./pkg', b'', tarfile.DIRTYPE), ('./pkg/package.json', b'', tarfile.SYMTYPE)],
                    [('./pkg/package.json', b'{}', tarfile.REGTYPE)],
                    [('.', b'{}', tarfile.REGTYPE)]]
        for members in variants:
            with self.subTest(members=members), self.assertRaises(M156CacheError): self.verify(raw=self.fixture(members))

    def test_wrong_size_hash_and_member_limits(self):
        data = self.fixture()
        with patch.object(module, 'ARCHIVE_SIZE', len(data)):
            with self.assertRaisesRegex(M156CacheError, 'hash'): module.verify_archive(io.BytesIO(data), {module.PREFIX+'x': 'a'*64})
        with patch.object(module, 'ARCHIVE_SIZE', len(data)-1):
            with self.assertRaisesRegex(M156CacheError, 'size'): module.archive_hash(io.BytesIO(data))
        with patch.object(module, 'ARCHIVE_SIZE', len(data)+1):
            with self.assertRaisesRegex(M156CacheError, 'truncated'): module.archive_hash(io.BytesIO(data))
        for name in ('MAX_MEMBERS', 'MAX_SELECTED', 'MAX_EXPANDED'):
            with self.subTest(name=name), patch.object(module, name, 1), self.assertRaises(M156CacheError): self.verify()

    def test_invalid_selected_prefix_path_digest_and_container_refused(self):
        for requested in ({'elsewhere/x': 'a'*64}, {module.PREFIX+'../outside': 'a'*64},
                          {module.PREFIX+'pkg/package.json': None}, {module.PREFIX+'node_modules.tar.gz': 'a'*64}, {}):
            with self.subTest(requested=requested), self.assertRaises(M156CacheError): self.verify(requested=requested)

    def deps(self, stanza=None, extra=''):
        value = stanza if stanza is not None else {'bucket':'chromium-nodejs','dep_type':'gcs',
                                                  'condition':'non_git_source','objects':[module.OBJECT]}
        return ("deps = {'src/third_party/node/node_modules': "+repr(value)+extra+'}\n').encode()

    def test_literal_pinned_object_no_deps_execution(self):
        raw = self.deps()
        with patch.object(module, 'DEPS_SHA256', module.sha(raw)):
            self.assertEqual(module.official_object(raw)['sha256sum'], module.ARCHIVE_SHA256)
            self.assertFalse(module.official_object(raw)['serverGenerationObserved'])

    def test_wrong_deps_pin_object_duplicate_and_executable_value_refused(self):
        with self.assertRaisesRegex(M156CacheError, 'official DEPS'): module.official_object(self.deps())
        values = [self.deps({'dep_type':'git'}), self.deps(extra=", 'src/third_party/node/node_modules': {}"),
                  b"deps = {'src/third_party/node/node_modules': dangerous()}\n"]
        for raw in values:
            with self.subTest(raw=raw), patch.object(module, 'DEPS_SHA256', module.sha(raw)), self.assertRaises((M156CacheError, ValueError)):
                module.official_object(raw)


if __name__ == '__main__': unittest.main()
