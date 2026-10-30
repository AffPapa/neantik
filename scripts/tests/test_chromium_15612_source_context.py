"""Real Git/byte/namespace invalidation; synthetic semantics are not runtime QA."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import chromium_15612_source_context as context
import chromium_15612_packaged_evidence as packaged
import chromium_15612_variant as variant

REAL_BINDING_CHECK = context._require_verifier_project
PROOF = variant.legacy.PREFIX + '-source-evidence/proof.json'


class SourceContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.project = self.base / 'project'
        self.project.mkdir()
        (self.project / 'runtime').mkdir()
        (self.project / 'scripts').mkdir()
        (self.project / 'scripts/chromium_15612_source_context.py').write_text('# verifier fixture\n')
        (self.project / '.gitignore').write_text('*.ignored\n')
        self.proof = self.project / 'runtime' / PROOF
        self.proof.parent.mkdir()
        self.proof.write_text('{"proof":"owned synthetic"}\n')
        self.lock = {'sourceVariant': variant.FONT_VARIANT,
                     'sourceContract': 'runtime/' + variant.FONT_PREFIX + '-source-contract.json',
                     'sourceProvenance': 'runtime/' + variant.FONT_PREFIX + '-port-candidate.json'}
        (self.project / self.lock['sourceProvenance']).write_text(json.dumps(self.lock))
        self.fields = {'sourceVariant': variant.FONT_VARIANT,
                       'sourceEvidenceMode': 'synthetic-unit-control', 'freshWholeSourceTreeObserved': False}
        # Only this unit fixture substitutes the loaded-module/project binding.
        # All Git/file/namespace checks remain real; actual source integration
        # runs on the verifier's real project without this substitute.
        binding = patch.object(context, '_require_verifier_project')
        binding.start()
        self.addCleanup(binding.stop)
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Owned QA', '-c', 'user.email=qa@example.invalid', 'commit', '-qm', 'fixture')

    def git(self, *args):
        env = {**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'}
        subprocess.run(['/usr/bin/git', '-C', str(self.project), *args],
                       check=True, capture_output=True, env=env)

    def create(self):
        # The source semantics entry is counted but mocked here. The integration
        # measurement separately executes the real reviewed candidate proof.
        with patch.object(variant, 'verify_candidate_lock') as check, \
             patch.object(variant, '_source_fields_from_verified_lock', return_value=self.fields), \
             patch.object(packaged, '_names', return_value=[PROOF]):
            value = context.verify_source_context(self.project, self.lock)
            check.assert_called_once()
            return value

    def evidence(self, name='evidence'):
        root = self.base / name
        root.mkdir()
        (root / PROOF).parent.mkdir()
        (root / PROOF).write_bytes(self.proof.read_bytes())
        (root / 'fingerprint-chromium.lock.json').write_text(json.dumps(self.lock))
        return root

    def test_two_copies_share_only_source_semantics_and_measure_runtime_each_time(self):
        a, b = self.evidence('a'), self.evidence('b')
        ctx = self.create()
        with patch.object(variant, 'verify_candidate_lock') as semantic, \
             patch.object(packaged.source, 'evidence_documents') as namespace, \
             patch.object(variant, '_verify_signed_runtime_closure') as runtime:
            for root in (a, b):
                packaged.process(self.project, root, self.lock, source_context=ctx)
                variant.verify_report_source_fields(self.fields, self.lock, project_root=self.project, source_context=ctx)
                variant.verify_signed_runtime_identity(root, self.lock, project_root=self.project, source_context=ctx)
            semantic.assert_not_called()
            namespace.assert_not_called()  # Identical proof bytes + fresh full namespace, not cached copy PASS.
            self.assertEqual(runtime.call_count, 2)
        returned = variant.report_source_fields(self.lock, project_root=self.project, source_context=ctx)
        returned['freshWholeSourceTreeObserved'] = True
        self.assertEqual(ctx.source_fields(), self.fields)

    def test_changed_copy_bytes_rejected_and_context_poisoned(self):
        root = self.evidence()
        ctx = self.create()
        (root / PROOF).write_text('corrupt')
        with self.assertRaisesRegex(ValueError, 'differs'):
            packaged.process(self.project, root, self.lock, source_context=ctx)
        with self.assertRaisesRegex(ValueError, 'invalid'):
            with ctx.operation(self.project, self.lock):
                pass

    def test_copy_lock_is_read_before_and_after_each_operation(self):
        for late in (False, True):
            with self.subTest(late=late):
                root = self.evidence('late' if late else 'early')
                ctx = self.create()
                leaf = root / 'fingerprint-chromium.lock.json'
                def change(*_args):
                    leaf.write_text('{}')
                if not late:
                    change()
                actual_read = packaged.source.checked_file
                def measured(parent, name):
                    value = actual_read(parent, name)
                    if late and parent / name == root / PROOF:
                        change()
                    return value
                with patch.object(packaged.source, 'checked_file', side_effect=measured), \
                     self.assertRaisesRegex(ValueError, 'lock'):
                    packaged.process(self.project, root, self.lock, source_context=ctx)

    def test_copied_namespace_validation_still_runs_and_failure_poisoned(self):
        root = self.evidence()
        ctx = self.create()
        (root / PROOF).with_name('extra.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'extra'):
            packaged.process(self.project, root, self.lock, source_context=ctx)
        with self.assertRaisesRegex(ValueError, 'invalid'):
            with ctx.operation(self.project, self.lock):
                pass

    def test_bad_report_not_authorized_by_source_context(self):
        ctx = self.create()
        with self.assertRaisesRegex(ValueError, 'mode/binding'):
            variant.verify_report_source_fields({**self.fields, 'freshWholeSourceTreeObserved': True},
                                               self.lock, project_root=self.project, source_context=ctx)
        with self.assertRaisesRegex(ValueError, 'invalid'):
            variant.report_source_fields(self.lock, project_root=self.project, source_context=ctx)

    def test_tracked_source_and_verifier_edits_invalidate(self):
        for relative in ('runtime/' + PROOF, 'scripts/chromium_15612_source_context.py'):
            with self.subTest(relative=relative):
                ctx = self.create()
                leaf = self.project / relative
                original = leaf.read_bytes()
                leaf.write_bytes(original + b' ')
                with self.assertRaisesRegex(ValueError, 'inputs changed'):
                    with ctx.operation(self.project, self.lock):
                        pass
                leaf.write_bytes(original)
                with self.assertRaisesRegex(ValueError, 'invalid'):
                    with ctx.operation(self.project, self.lock):
                        pass

    def test_ignored_namespace_addition_and_same_bytes_replacement_invalidate(self):
        ctx = self.create()
        leaf = self.project / 'runtime/added.ignored'
        leaf.write_text('not tracked but changes the sealed namespace')
        with self.assertRaisesRegex(ValueError, 'inputs changed'):
            with ctx.operation(self.project, self.lock):
                pass
        leaf.unlink()
        ctx = self.create()
        old = self.proof
        replacement = self.project / 'runtime/replacement.ignored'
        replacement.write_bytes(old.read_bytes())
        replacement.replace(old)
        with self.assertRaisesRegex(ValueError, 'inputs changed'):
            with ctx.operation(self.project, self.lock):
                pass

    def test_changed_lock_root_environment_interpreter_import_path_and_cwd_refuse(self):
        ctx = self.create()
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            with ctx.operation(self.project, {**self.lock, 'changed': True}):
                pass
        ctx = self.create()
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            with ctx.operation(self.base, self.lock):
                pass
        for target, value in [('version', 'different-python'), ('path', [*sys.path, str(self.base)])]:
            ctx = self.create()
            with patch.object(sys, target, value), self.assertRaisesRegex(ValueError, 'identity changed'):
                with ctx.operation(self.project, self.lock):
                    pass
        ctx = self.create()
        with patch.dict(os.environ, {'NEANTIK_CONTEXT_QA': 'synthetic-value'}), \
             self.assertRaisesRegex(ValueError, 'identity changed'):
            with ctx.operation(self.project, self.lock):
                pass
        self.assertNotIn('synthetic-value', repr(ctx))
        ctx = self.create()
        previous = Path.cwd()
        try:
            os.chdir(self.base)
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                with ctx.operation(self.project, self.lock):
                    pass
        finally:
            os.chdir(previous)

    def test_interrupt_and_mid_operation_change_never_reuse(self):
        ctx = self.create()
        with self.assertRaises(KeyboardInterrupt):
            with ctx.operation(self.project, self.lock):
                raise KeyboardInterrupt()
        with self.assertRaisesRegex(ValueError, 'invalid'):
            with ctx.operation(self.project, self.lock):
                pass
        ctx = self.create()
        with self.assertRaisesRegex(ValueError, 'inputs changed'):
            with ctx.operation(self.project, self.lock):
                (self.project / 'runtime/mid.ignored').write_text('change')

    def test_failed_validation_has_no_context_and_no_trusted_json_constructor(self):
        with patch.object(packaged, '_verified_source_expectations', side_effect=ValueError('bad source')), \
             self.assertRaisesRegex(ValueError, 'bad source'):
            context.verify_source_context(self.project, self.lock)
        with self.assertRaisesRegex(ValueError, 'completed in-process'):
            context.VerifiedSourceContext(None, b'{}', b'{}', (), (), object())
        self.proof.write_text('dirty')
        with self.assertRaises(context.SourceContextUnavailable):
            context.verify_source_context(self.project, self.lock)

    def test_actual_verifier_binding_refuses_another_project(self):
        with self.assertRaisesRegex(context.SourceContextUnavailable, "running verifier"):
            REAL_BINDING_CHECK(self.project)

    def test_foreign_own_helper_binding_is_a_hard_failure(self):
        actual_project = Path(context.__file__).resolve().parents[1]
        for name in ('chromium_additive_source_delta', 'security_backport_source_delta',
                     'runtime_historical_baseline'):
            foreign = types.ModuleType(name)
            foreign.__file__ = str(self.base / (name + '.py'))
            with self.subTest(name=name), patch.dict(sys.modules, {name: foreign}):
                with self.assertRaisesRegex(ValueError, 'module binding') as failure:
                    REAL_BINDING_CHECK(actual_project)
                self.assertNotIsInstance(failure.exception, context.SourceContextUnavailable)

    def test_clean_snapshot_failure_is_not_development_fallback(self):
        with patch.object(context, 'capture_release_source',
                          side_effect=context.ReleaseSourceReceiptError('changed after preflight')):
            with self.assertRaisesRegex(ValueError, 'clean preflight') as failure:
                context.verify_source_context(self.project, self.lock)
            self.assertNotIsInstance(failure.exception, context.SourceContextUnavailable)

    def test_source_change_during_validation_never_creates_context(self):
        def changed(*_args):
            self.proof.write_text('changed during semantic validation')
            return self.fields, [PROOF]
        with patch.object(packaged, '_verified_source_expectations', side_effect=changed), \
             self.assertRaisesRegex(ValueError, 'inputs changed'):
            context.verify_source_context(self.project, self.lock)

    def test_missing_or_linked_copy_never_uses_cached_success(self):
        for linked in (False, True):
            with self.subTest(linked=linked):
                root = self.evidence('linked' if linked else 'missing')
                ctx = self.create()
                target = root / PROOF
                target.unlink()
                if linked:
                    target.symlink_to(self.proof)
                with self.assertRaises((ValueError, OSError)):
                    packaged.process(self.project, root, self.lock, source_context=ctx)
                with self.assertRaisesRegex(ValueError, 'invalid'):
                    with ctx.operation(self.project, self.lock):
                        pass

    def test_copied_proof_replaced_during_fd_read_is_rejected(self):
        root = self.evidence()
        ctx = self.create()
        target = root / PROOF
        replacement = target.with_name('replacement')
        replacement.write_bytes(target.read_bytes())
        actual_stat = os.lstat
        replaced = False
        def changed(path, *args, **kwargs):
            nonlocal replaced
            if Path(path) == target and not replaced:
                replacement.replace(target)
                replaced = True
            return actual_stat(path, *args, **kwargs)
        # checked_file holds the real FD while this controlled replacement
        # occurs immediately before its current-path inode comparison.
        with patch.object(os, 'lstat', side_effect=changed), \
             self.assertRaisesRegex(ValueError, 'changed while reading'):
            packaged.process(self.project, root, self.lock, source_context=ctx)
        self.assertTrue(replaced)


if __name__ == '__main__':
    unittest.main()
