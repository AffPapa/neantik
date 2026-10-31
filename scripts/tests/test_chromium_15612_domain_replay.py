import copy
import hashlib
import io
import re
import tarfile
import unittest
from unittest.mock import patch
import zlib
import chromium_15612_domain_replay as module
from chromium_15612_generated_cache import M156CacheError


class DomainReplayTests(unittest.TestCase):
    recipe = b'google\\.com#blocked.invalid\n'
    sources = {'a.cc': b'https://google.com/', 'latin.cc': b'\xff google.com', 'same.cc': b'local only'}

    def fixture(self, mutate=None):
        pre = {n: module.sha(raw) for n, raw in self.sources.items()}
        changed = {n: raw.replace(b'google.com', b'blocked.invalid') for n, raw in self.sources.items() if n != 'same.cc'}
        post = {**pre, **{n: module.sha(raw) for n, raw in changed.items()}}
        members = [('orig/'+n, raw, tarfile.REGTYPE) for n, raw in self.sources.items() if n != 'same.cc']
        index = ''.join(f'{n}|{zlib.crc32(raw):08x}\n' for n, raw in changed.items()).encode()
        members.append(('cache_index.list', index, tarfile.REGTYPE))
        if mutate: mutate(members, pre, post)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
            for name, raw, kind in members:
                entry = tarfile.TarInfo(name); entry.type = kind
                entry.size = len(raw) if kind == tarfile.REGTYPE else 0
                if kind == tarfile.SYMTYPE: entry.linkname = '../outside'
                archive.addfile(entry, io.BytesIO(raw) if entry.size else None)
        raw = buffer.getvalue()
        return io.BytesIO(raw), dict(expected_archive_sha256=module.sha(raw), recipe=self.recipe,
                                    preimages=pre, postimages=post,
                                    unchanged_bytes={'same.cc': self.sources['same.cc']})

    def run_fixture(self, mutate=None, alter=None):
        stream, args = self.fixture(mutate)
        if alter: alter(args)
        # Only the owned fixture recipe differs from the exact production recipe.
        with patch.object(module, 'recipe_pairs', return_value=((re.compile(r'google\.com'), 'blocked.invalid'),)):
            return module.verify_archive(stream, **args)

    def test_actual_in_memory_byte_replay_and_scope(self):
        report = self.run_fixture()
        self.assertEqual(report['changedSourceCount'], 2)
        self.assertEqual(report['substitutionCount'], 2)
        self.assertTrue(report['unchangedSourcesReplayed'])
        self.assertFalse(report['releaseReady'])
        self.assertTrue(report['pristineOriginsStillRequired'])

    def test_empty_latin1_and_repeated_sequential_substitutions(self):
        pairs = ((re.compile('google.com'), 'blocked'), (re.compile('blocked'), 'local'))
        self.assertEqual(module.substitute(b'', pairs), (b'', 0))
        self.assertEqual(module.substitute(b'\xff google.com google.com', pairs), (b'\xff local local', 4))

    def test_identity_substitution_is_legitimate_cached_unchanged_bytes(self):
        original = b'https://goo.gl/x'
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
            for name, raw in [('orig/identity.cc', original),
                              ('cache_index.list', f'identity.cc|{zlib.crc32(original):08x}\n'.encode())]:
                entry = tarfile.TarInfo(name); entry.size = len(raw)
                archive.addfile(entry, io.BytesIO(raw))
        data = buffer.getvalue()
        pairs = ((re.compile(r'goo\.gl(e?)'), r'goo.gl\g<1>'),)
        with patch.object(module, 'recipe_pairs', return_value=pairs):
            result = module.verify_archive(io.BytesIO(data), expected_archive_sha256=module.sha(data),
                                           recipe=self.recipe, preimages={'identity.cc': module.sha(original)},
                                           postimages={'identity.cc': module.sha(original)}, unchanged_bytes={})
        self.assertEqual(result['changedSourceCount'], 0)
        self.assertEqual(result['cachedSourceCount'], 1)
        self.assertEqual(result['substitutionCount'], 1)

    def test_pax_long_path_is_supported_but_other_pax_overrides_are_refused(self):
        name = 'dir/'+'long/'*25+'source.cc'
        def long(members, pre, post):
            old = members[0][1]
            members[0] = ('orig/'+name, old, tarfile.REGTYPE)
            pre[name] = pre.pop('a.cc'); post[name] = post.pop('a.cc')
            members[-1] = ('cache_index.list', members[-1][1].replace(b'a.cc|', name.encode()+b'|'), tarfile.REGTYPE)
        self.assertEqual(self.run_fixture(long)['cachedSourceCount'], 2)
        stream, args = self.fixture()
        buffer = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='r:gz') as existing, tarfile.open(fileobj=buffer, mode='w:gz') as out:
            for entry in existing:
                content = existing.extractfile(entry).read()
                entry.pax_headers = {'comment': 'not part of native writer'}
                out.addfile(entry, io.BytesIO(content))
        raw = buffer.getvalue(); args['expected_archive_sha256'] = module.sha(raw)
        with patch.object(module, 'recipe_pairs', return_value=((re.compile(r'google\.com'), 'blocked.invalid'),)):
            with self.assertRaisesRegex(M156CacheError, 'PAX metadata'):
                module.verify_archive(io.BytesIO(raw), **args)

    def test_recipe_and_schedule_cannot_be_changed_by_caller(self):
        for raw in (self.recipe, b'', b'bad#bad#bad', b'.*#invented\n'):
            with self.subTest(raw=raw), self.assertRaisesRegex(M156CacheError, 'Exact reviewed'):
                module.recipe_pairs(raw)
        with self.assertRaisesRegex(M156CacheError, 'Exact reviewed'):
            module.verify_schedule(b'a.cc\n', {'a.cc': 'a'*64}, [])

    def test_corrupt_original_and_stale_postimage_rejected_independently(self):
        with self.assertRaisesRegex(M156CacheError, 'preimage'):
            self.run_fixture(lambda m,p,q: m.__setitem__(0, ('orig/a.cc', b'altered', tarfile.REGTYPE)))
        with self.assertRaisesRegex(M156CacheError, 'postimage'):
            self.run_fixture(alter=lambda a: a['postimages'].__setitem__('a.cc', 'f'*64))

    def test_wrong_archive_pin_and_crc_rejected(self):
        with self.assertRaisesRegex(M156CacheError, 'archive digest'):
            self.run_fixture(alter=lambda a: a.__setitem__('expected_archive_sha256', 'a'*64))
        with self.assertRaisesRegex(M156CacheError, 'CRC index'):
            self.run_fixture(lambda m,p,q: m.__setitem__(-1, ('cache_index.list', b'a.cc|00000000\nlatin.cc|00000000\n', tarfile.REGTYPE)))

    def test_duplicates_links_traversal_extra_and_missing_members_rejected(self):
        changes = [lambda m,p,q: m.append(m[0]), lambda m,p,q: m.pop(0),
                   lambda m,p,q: m.__setitem__(0, ('orig/../outside', b'x', tarfile.REGTYPE)),
                   lambda m,p,q: m.__setitem__(0, ('orig/a.cc', b'', tarfile.SYMTYPE)),
                   lambda m,p,q: m.__setitem__(0, ('orig/unlisted.cc', b'x', tarfile.REGTYPE)),
                   lambda m,p,q: m.pop()]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(M156CacheError): self.run_fixture(change)

    def test_unexpected_and_duplicate_index_entries_refused(self):
        for index in (b'a.cc|00000000\na.cc|00000000\n', b'outside|00000000\n', b'a.cc|zzzzzzzz\n'):
            with self.subTest(index=index), self.assertRaises(M156CacheError):
                self.run_fixture(lambda m,p,q: m.__setitem__(-1, ('cache_index.list', index, tarfile.REGTYPE)))

    def test_unchanged_bytes_coverage_digest_and_false_declaration_rejected(self):
        for value in ({}, {'same.cc': b'wrong'}, {'same.cc': b'google.com'}):
            with self.subTest(value=value), self.assertRaises(M156CacheError):
                self.run_fixture(alter=lambda a: a.__setitem__('unchanged_bytes', value))
        def dishonest(args):
            raw = b'google.com'
            args['unchanged_bytes'] = {'same.cc': raw}
            args['preimages']['same.cc'] = args['postimages']['same.cc'] = module.sha(raw)
        with self.assertRaisesRegex(M156CacheError, 'actually substitutes'): self.run_fixture(alter=dishonest)

    def test_partial_scope_and_decompression_limits(self):
        result = self.run_fixture(alter=lambda a: a.__setitem__('unchanged_bytes', None))
        self.assertFalse(result['unchangedSourcesReplayed'])
        for name, bound in (('MAX_ARCHIVE', 1), ('MAX_MEMBER', 1), ('MAX_EXPANDED', 1)):
            with self.subTest(name=name), patch.object(module, name, bound), self.assertRaises(M156CacheError):
                self.run_fixture()

    def test_image_path_and_null_digest_are_not_absence_proofs(self):
        for mapping in ({'../outside': 'a'*64}, {'a.cc': None}, {'a.cc': True}):
            with self.subTest(mapping=mapping), self.assertRaises(M156CacheError):
                self.run_fixture(alter=lambda a: a.update(preimages=copy.copy(mapping), postimages=copy.copy(mapping)))


if __name__ == '__main__': unittest.main()
