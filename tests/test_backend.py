import importlib.util
from datetime import datetime
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('pulse', Path(__file__).parents[1] / 'backend.py')
pulse = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pulse)


def snapshot(reset=1000, used=90, weekly=40):
    return {'ordinaryUsageAllowed': True, 'spendControlReached': False,
            'primary': {'windowDurationMins': 300, 'resetsAt': reset, 'usedPercent': used},
            'secondary': {'windowDurationMins': 10080, 'resetsAt': 50000, 'usedPercent': weekly}}


class ResetTests(unittest.TestCase):
    def test_first_read_arms_without_prompt(self):
        record = {}
        self.assertIsNone(pulse.decide(snapshot(), record, 900)[0])
        self.assertEqual(record['target'], 1000)

    def test_only_after_reset_and_grace_with_server_permission(self):
        record = {'target': 1000}
        for now in (900, 1000, 1014):
            self.assertIsNone(pulse.decide(snapshot(19000, 0), record, now)[0])
        self.assertEqual(pulse.decide(snapshot(19000, 0), record, 1015)[0], 1000)
        for permission in (None, False):
            data = snapshot(19000, 0)
            data['ordinaryUsageAllowed'] = permission
            self.assertIsNone(pulse.decide(data, record, 1015)[0])

    def test_weekly_spending_and_unknown_usage_block(self):
        for data in (snapshot(19000, 0, 100), snapshot(19000, 100), snapshot(19000, None)):
            self.assertIsNone(pulse.decide(data, {'target': 1000}, 1015)[0])
        data = snapshot(19000, 0)
        data['spendControlReached'] = True
        self.assertIsNone(pulse.decide(data, {'target': 1000}, 1015)[0])
        data['spendControlReached'] = False
        data['rateLimitReachedType'] = 'weekly'
        self.assertIsNone(pulse.decide(data, {'target': 1000}, 1015)[0])

    def test_stale_snapshot_does_not_trigger_but_zero_usage_confirms(self):
        self.assertIsNone(pulse.decide(snapshot(), {'target': 1000}, 1015)[0])
        self.assertEqual(pulse.decide(snapshot(1000, 0), {'target': 1000}, 1015)[0], 1000)

    def test_attempt_journal_survives_restart_and_alias_profile(self):
        record = json.loads(json.dumps({'target': 1000, 'attempted': 1000}))
        self.assertIsNone(pulse.decide(snapshot(19000, 0), record, 1015)[0])
        self.assertEqual(record['target'], 19000)
        self.assertIsNone(pulse.decide(snapshot(19000, 0), record, 1016)[0])
        self.assertEqual(pulse.decide(snapshot(37000, 0), record, 19015)[0], 19000)

    def test_sleep_skips_backlog(self):
        record = {'target': 1000}
        self.assertEqual(pulse.decide(snapshot(73000, 0), record, 60000)[0], 1000)
        record.update(attempted=1000, target=73000)
        self.assertIsNone(pulse.decide(snapshot(73000, 0), record, 60001)[0])

    def test_missing_or_nonfivehour_window_never_sends(self):
        for value in (None, {'windowDurationMins': 60, 'resetsAt': 1000, 'usedPercent': 0},
                      {'windowDurationMins': 300, 'resetsAt': None, 'usedPercent': 0}):
            self.assertIsNone(pulse.decide({'primary': value}, {'target': 1000}, 1015)[0])

    def test_reset_only_has_no_periodic_checks_and_custom_retry_is_used(self):
        settings = dict(pulse.DEFAULT_SETTINGS)
        self.assertEqual(pulse.next_check(0, settings, snapshot(50000), {'target': 50000}), 50015)
        self.assertEqual(pulse.next_check(900, settings, snapshot(), {'target': 1000}), 1015)
        settings['retryInterval'] = 17
        self.assertEqual(pulse.next_check(1100, settings, snapshot(), {'target': 1000}), 2120)
        settings.update(mode='periodic', interval=47)
        self.assertEqual(pulse.next_check(0, settings, snapshot(50000), {'target': 50000}), 2820)
        self.assertEqual(pulse.next_check(900, settings, snapshot(), {'target': 1000}), 1015)

    def test_api_credentials_are_not_inherited_and_homes_are_isolated(self):
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'test-only', 'CODEX_HOME': '/wrong'}):
            env = pulse.child_env(Path('/account-one'))
        self.assertNotIn('OPENAI_API_KEY', env)
        self.assertEqual(env['CODEX_HOME'], '/account-one')

    def test_identity_deduplicates_profiles_without_storing_token(self):
        self.assertEqual(pulse.identity({'email': 'TEST@example.com'}, {'accountId': 'one'}),
                         pulse.identity({'email': 'test@example.com'}, {'accountId': 'one'}))
        self.assertNotEqual(pulse.identity({'email': 'test@example.com'}, {'accountId': 'one'}),
                            pulse.identity({'email': 'test@example.com'}, {'accountId': 'two'}))
        self.assertIsNone(pulse.identity({'email': 'test@example.com'}, {}))


class IntegrationTests(unittest.TestCase):
    def test_paused_read_never_prompts_and_start_sends_only_once_after_reset(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            profiles = root / 'profiles'
            home = profiles / 'account-test'
            home.mkdir(parents=True)
            (home / 'auth.json').write_text('{}')
            state_dir = root / 'state'
            state_dir.mkdir()
            account = {'email': 'fixture@example.com', 'type': 'chatgpt', 'planType': 'plus'}
            response = {'accountId': 'fixture'}
            owner = pulse.identity(account, response)
            with patch.object(pulse, 'codex_executable', return_value='/fake'):
                watcher = pulse.Watcher(profiles, state_dir, lambda _: None)
            watcher.state['journal'][owner] = {'target': 1000}
            with patch.object(pulse, 'read_account', return_value=(account, response, snapshot(19000, 0))), \
                 patch.object(pulse.time, 'time', return_value=1020), \
                 patch.object(pulse, 'send_prompt', return_value=True) as send:
                watcher.check('account-test', watcher.epoch)
                send.assert_not_called()
                watcher.command({'action': 'start'})
                watcher.check('account-test', watcher.epoch)
                send.assert_called_once()
                saved = json.loads(watcher.path.read_text())
                self.assertEqual(saved['journal'][owner]['attempted'], 1000)
                watcher.check('account-test', watcher.epoch)
                send.assert_called_once()

    def test_stop_between_decision_and_launch_is_rechecked(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            profiles = root / 'profiles'
            home = profiles / 'account-test'
            home.mkdir(parents=True)
            (home / 'auth.json').write_text('{}')
            state_dir = root / 'state'
            state_dir.mkdir()
            account = {'email': 'fixture@example.com', 'type': 'chatgpt'}
            response = {'accountId': 'fixture'}
            with patch.object(pulse, 'codex_executable', return_value='/fake'):
                watcher = pulse.Watcher(profiles, state_dir, lambda _: None)
            watcher.state['journal'][pulse.identity(account, response)] = {'target': 1000}
            watcher.command({'action': 'start'})

            def stop_before_launch(codex, profile, children, launch):
                watcher.command({'action': 'pause'})
                with self.assertRaises(pulse.Cancelled):
                    launch(['/bin/echo', 'should-never-run'], profile, folder)
                return False

            with patch.object(pulse, 'read_account', return_value=(account, response, snapshot(19000, 0))), \
                 patch.object(pulse.time, 'time', return_value=1020), \
                 patch.object(pulse, 'send_prompt', side_effect=stop_before_launch):
                watcher.check('account-test', watcher.epoch)
                self.assertFalse(watcher.children.active)
                self.assertFalse(watcher.running)

    def test_rpc_handshake_and_codex_home_using_fake_cli(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            home = root / 'account-test'
            home.mkdir()
            (home / 'auth.json').write_text('{}')
            fake = root / 'codex'
            fake.write_text('''#!/usr/bin/python3
import json, os, sys
for line in sys.stdin:
    req = json.loads(line)
    method = req['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {}
    elif method == 'account/read':
        result = {'account': {'type':'chatgpt', 'email':'fixture@example.com', 'planType':'plus'}}
    elif method == 'account/rateLimits/read':
        assert os.environ['CODEX_HOME'].endswith('account-test')
        result = {'accountId':'fixture', 'ordinaryUsageAllowed': True,
                  'rateLimits': {'primary': {'windowDurationMins':300, 'resetsAt':90000, 'usedPercent':3}}}
    else: raise RuntimeError('unexpected method')
    print(json.dumps({'id':req['id'], 'result':result}), flush=True)
''')
            fake.chmod(0o700)
            children = pulse.Children()
            account, response, data = pulse.read_account(str(fake), home, children)
            self.assertEqual(account['email'], 'fixture@example.com')
            self.assertTrue(data['ordinaryUsageAllowed'])
            self.assertFalse(children.active)
            self.assertEqual(pulse.discover(root), [home])

    def test_stop_cancels_running_child_and_blocks_new_launches(self):
        children = pulse.Children()
        with tempfile.TemporaryDirectory() as folder:
            proc = children.launch(['/bin/sleep', '60'], Path(folder), folder)
            children.cancel_all()
            proc.wait(timeout=3)
            self.assertNotEqual(proc.returncode, 0)
            with self.assertRaises(pulse.Cancelled):
                children.launch(['/bin/echo', 'should-not-run'], Path(folder), folder)
            children.finish(proc)
            self.assertFalse(children.active)

    def test_pause_and_restart_settings_and_corrupt_network_do_not_send(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            profiles = root / 'profiles'
            home = profiles / 'account-test'
            home.mkdir(parents=True)
            (home / 'auth.json').write_text('{}')
            state = root / 'state'
            state.mkdir()
            events = []
            with patch.object(pulse, 'codex_executable', return_value='/fake'):
                watcher = pulse.Watcher(profiles, state, events.append)
                watcher.command({'action': 'settings', 'settings': {'interval': 47}})
                watcher.command({'action': 'start'})
                self.assertTrue(watcher.running)
                watcher.command({'action': 'pause'})
                self.assertFalse(watcher.running)
                with patch.object(pulse, 'read_account', side_effect=RuntimeError('offline')), \
                     patch.object(pulse, 'send_prompt') as send:
                    watcher.check('account-test', watcher.epoch)
                    send.assert_not_called()
                second = pulse.Watcher(profiles, state, events.append)
                self.assertFalse(second.running)
                self.assertEqual(second.settings['interval'], 47)
            self.assertEqual(os.stat(watcher.path).st_mode & 0o777, 0o600)


class AdvancedFeatureTests(unittest.TestCase):
    def make_watcher(self, directory, loaded=None, force_paused=False):
        root = Path(directory)
        profiles = root / 'profiles'
        home = profiles / 'account-test'
        home.mkdir(parents=True, exist_ok=True)
        (home / 'auth.json').write_text('{}')
        state = root / 'state'
        state.mkdir(exist_ok=True)
        if loaded is not None:
            (state / 'state.json').write_text(json.dumps(loaded))
        events = []
        with patch.object(pulse, 'codex_executable', return_value='/fake'):
            watcher = pulse.Watcher(profiles, state, events.append, force_paused=force_paused)
        return watcher, events

    def test_default_home_is_discovered_and_used_for_status(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            default = root / '.codex'
            default.mkdir()
            (default / 'auth.json').write_text('{}')
            profiles = root / 'profiles'
            profiles.mkdir()
            state = root / 'state'
            state.mkdir()
            with patch.object(pulse, 'DEFAULT_ROOT', profiles), \
                 patch.object(pulse, 'DEFAULT_HOME', default), \
                 patch.object(pulse, 'codex_executable', return_value='/fake'):
                watcher = pulse.Watcher(profiles, state, lambda _: None)
                self.assertIn('default', watcher.accounts)
                with patch.object(pulse, 'read_account', return_value=(
                        {'email': 'default@example.com'}, {'accountId': 'default'}, snapshot(19000, 0, 100))) as read, \
                     patch.object(pulse, 'send_prompt') as send:
                    watcher.check('default', watcher.epoch, allow_trigger=False)
                    self.assertEqual(read.call_args.args[1], default)
                    send.assert_not_called()
                row = watcher.accounts['default']
                self.assertEqual(row['weeklyResetsAt'], 50000)
                self.assertEqual(row['resetsAt'], 19000)
                self.assertIn('Haftalık limit dolu', row['status'])

    def test_migration_keeps_journal_and_disabled_accounts(self):
        old = {'interval': 20, 'profiles': {'account-test': False},
               'journal': {'owner': {'target': 1000, 'attempted': 1000}}}
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder, old)
            self.assertFalse(watcher.running)
            self.assertEqual(watcher.settings['mode'], 'reset')
            self.assertEqual(watcher.settings['interval'], 20)
            self.assertFalse(watcher.accounts['account-test']['enabled'])
            self.assertEqual(watcher.state['journal'], old['journal'])

    def test_manual_minutes_validation_and_atomic_rejection(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            for invalid in (0, -1, 10081, 3.5, True, '20', None):
                watcher.command({'action': 'settings', 'settings': {'interval': invalid}})
                self.assertEqual(watcher.settings['interval'], 30)
                self.assertIsNotNone(watcher.command_error)
            watcher.command({'action': 'settings', 'settings': {'mode': 'periodic', 'interval': 137, 'retryInterval': 19}})
            self.assertEqual(watcher.settings['interval'], 137)
            self.assertEqual(watcher.settings['retryInterval'], 19)
            self.assertIsNone(watcher.command_error)

    def test_alias_and_account_override_persist_without_changing_globals(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            watcher.command({'action': 'profile', 'id': 'account-test', 'settings': {
                'alias': '  İş hesabı  ', 'overrideEnabled': True, 'mode': 'periodic',
                'interval': 43, 'retryInterval': 11}})
            self.assertEqual(watcher.effective('account-test')['interval'], 43)
            self.assertEqual(watcher.effective('account-test')['mode'], 'periodic')
            self.assertEqual(watcher.settings['mode'], 'reset')
            watcher.publish()
            watcher2, events = self.make_watcher(folder)
            watcher2.publish()
            self.assertEqual(events[-1]['accounts'][0]['alias'], 'İş hesabı')
            watcher2.command({'action': 'profile', 'id': 'account-test', 'settings': {'overrideEnabled': False}})
            self.assertEqual(watcher2.effective('account-test')['mode'], 'reset')

    def test_auto_start_is_explicit_and_can_be_overridden_for_update(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            self.assertFalse(watcher.running)
            watcher.command({'action': 'settings', 'settings': {'autoStart': True}})
            self.assertFalse(watcher.running)  # Preference affects only the next launch.
            reopened, _ = self.make_watcher(folder)
            self.assertTrue(reopened.running)
            safe_update, _ = self.make_watcher(folder, force_paused=True)
            self.assertFalse(safe_update.running)
            self.assertTrue(safe_update.settings['autoStart'])

    def test_quiet_hours_day_and_midnight_boundaries(self):
        def stamp(day, hour, minute=0):
            return datetime(2026, 11, day, hour, minute).timestamp()
        settings = {**pulse.DEFAULT_SETTINGS, 'quietEnabled': True, 'quietStart': '23:00', 'quietEnd': '08:00'}
        self.assertIsNone(pulse.quiet_until(stamp(4, 22, 59), settings))
        self.assertEqual(pulse.quiet_until(stamp(4, 23), settings), stamp(5, 8))
        self.assertEqual(pulse.quiet_until(stamp(5, 7, 59), settings), stamp(5, 8))
        self.assertIsNone(pulse.quiet_until(stamp(5, 8), settings))
        settings.update(quietStart='09:00', quietEnd='17:00')
        self.assertEqual(pulse.quiet_until(stamp(5, 12), settings), stamp(5, 17))
        self.assertIsNone(pulse.quiet_until(stamp(5, 18), settings))

    def test_invalid_quiet_hours_rejected_without_partial_save(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            for start, end in (('24:00', '08:00'), ('9:00', '08:00'), ('09:00', '09:00'), ('aa:bb', '08:00')):
                watcher.command({'action': 'settings', 'settings': {'quietEnabled': True, 'quietStart': start, 'quietEnd': end}})
                self.assertFalse(watcher.settings['quietEnabled'])
                self.assertIsNotNone(watcher.command_error)

    def test_weekly_full_waits_for_weekly_reset_and_no_short_polling(self):
        settings = {**pulse.DEFAULT_SETTINGS, 'mode': 'periodic', 'interval': 1}
        self.assertEqual(pulse.next_check(1100, settings, snapshot(19000, 0, 100), {'target': 1000}), 50015)

    def test_quiet_hours_do_not_insert_an_earlier_unnecessary_check(self):
        now = datetime(2026, 11, 4, 23, 30).timestamp()
        reset = datetime(2026, 11, 5, 13).timestamp()
        settings = {**pulse.DEFAULT_SETTINGS, 'quietEnabled': True}
        self.assertEqual(pulse.next_check(now, settings, snapshot(reset, 0), {'target': reset}), reset + pulse.GRACE)

    def test_quiet_hours_defer_prompt_without_consuming_attempt(self):
        now = datetime(2026, 11, 4, 23, 30).timestamp()
        account = {'email': 'fixture@example.com', 'type': 'chatgpt'}
        response = {'accountId': 'fixture'}
        owner = pulse.identity(account, response)
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            watcher.command({'action': 'settings', 'settings': {'quietEnabled': True}})
            watcher.command({'action': 'start'})
            watcher.state['journal'][owner] = {'target': now - 60}
            with patch.object(pulse, 'read_account', return_value=(account, response, snapshot(now + 18000, 0))), \
                 patch.object(pulse.time, 'time', return_value=now), patch.object(pulse, 'send_prompt') as send:
                watcher.check('account-test', watcher.epoch)
                send.assert_not_called()
            self.assertNotIn('attempted', watcher.state['journal'][owner])
            self.assertEqual(watcher.accounts['account-test']['nextCheckAt'], datetime(2026, 11, 5, 8).timestamp())

    def test_manual_refresh_while_running_does_not_send_prompt(self):
        account = {'email': 'fixture@example.com', 'type': 'chatgpt'}
        response = {'accountId': 'fixture'}
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            watcher.command({'action': 'start'})
            watcher.command({'action': 'refresh'})
            self.assertTrue(watcher.status_only)
            watcher.state['journal'][pulse.identity(account, response)] = {'target': 1000}
            with patch.object(pulse, 'read_account', return_value=(account, response, snapshot(19000, 0))), \
                 patch.object(pulse.time, 'time', return_value=1020), patch.object(pulse, 'send_prompt') as send:
                watcher.check('account-test', watcher.epoch, allow_trigger=False)
                send.assert_not_called()

    def test_wake_rechecks_automatically_only_when_running(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            watcher.refresh = False
            watcher.command({'action': 'wake'})
            self.assertFalse(watcher.refresh)
            watcher.command({'action': 'start'})
            watcher.command({'action': 'refresh'})
            self.assertTrue(watcher.status_only)
            watcher.command({'action': 'wake'})
            self.assertTrue(watcher.refresh)
            self.assertFalse(watcher.status_only)

    def test_history_is_bounded_and_clearing_does_not_erase_journal(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            watcher.state['journal']['owner'] = {'attempted': 1000}
            # Fast fixture save; persistence itself is tested by migration/restart.
            with patch.object(watcher, 'save'):
                for index in range(pulse.MAX_HISTORY + 15):
                    watcher.event('check', str(index), 'account-test')
            self.assertEqual(len(watcher.state['history']), pulse.MAX_HISTORY)
            self.assertEqual(watcher.state['history'][0]['message'], '15')
            watcher.command({'action': 'clearHistory'})
            self.assertEqual(watcher.state['history'], [])
            self.assertEqual(watcher.state['journal']['owner']['attempted'], 1000)

    def test_notifications_opt_in_and_suppressed_in_quiet_hours(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.event('success', 'done', notify=True)
            self.assertFalse(any(e.get('notification') for e in events))
            watcher.command({'action': 'settings', 'settings': {'notificationsEnabled': True}})
            watcher.event('success', 'done', notify=True)
            self.assertTrue(events[-1]['notification'])
            before = len([e for e in events if e.get('notification')])
            watcher.command({'action': 'settings', 'settings': {'quietEnabled': True}})
            now = datetime(2026, 11, 4, 23, 30).timestamp()
            with patch.object(pulse.time, 'time', return_value=now):
                watcher.event('success', 'quiet', notify=True)
            self.assertEqual(len([e for e in events if e.get('notification')]), before)

    def test_settings_changes_do_not_trigger_network_requests(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.refresh = False
            with patch.object(pulse, 'read_account') as read:
                watcher.command({'action': 'settings', 'settings': {'mode': 'reset', 'selectedAccountId': 'account-test'}})
                watcher.command({'action': 'profile', 'id': 'account-test', 'settings': {'alias': 'Arkadaş'}})
                read.assert_not_called()
            self.assertFalse(watcher.refresh)
            self.assertEqual(events[-1]['settings']['selectedAccountId'], 'account-test')

    def test_profile_save_acknowledges_only_after_successful_persistence(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.command({'action': 'profile', 'id': 'account-test', 'requestId': 'save-one',
                             'settings': {'alias': 'İş hesabı'}})
            self.assertEqual(events[-1]['commandResult'], {'id': 'save-one', 'ok': True, 'message': None})
            saved = json.loads(watcher.path.read_text())
            self.assertEqual(saved['profiles']['account-test']['alias'], 'İş hesabı')

    def test_invalid_profile_save_reports_failure_for_matching_request(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.command({'action': 'profile', 'id': 'account-test', 'requestId': 'save-bad',
                             'settings': {'alias': 'not allowed\n'}})
            result = events[-1]['commandResult']
            self.assertEqual(result['id'], 'save-bad')
            self.assertFalse(result['ok'])
            self.assertIsNotNone(result['message'])
            self.assertNotIn('alias', watcher.preference('account-test'))

    def test_profile_save_disk_failure_does_not_acknowledge_success(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            with patch.object(watcher, 'save', side_effect=OSError('disk full')):
                watcher.command({'action': 'profile', 'id': 'account-test', 'requestId': 'save-disk',
                                 'settings': {'alias': 'İş hesabı'}})
            self.assertFalse(events[-1]['commandResult']['ok'])
            self.assertEqual(events[-1]['commandResult']['id'], 'save-disk')
            self.assertFalse(watcher.running)


    def test_disabled_account_is_not_read_even_when_check_called_directly(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder, {'profiles': {'account-test': {'enabled': False}}})
            with patch.object(pulse, 'read_account') as read:
                watcher.check('account-test', watcher.epoch)
                read.assert_not_called()
            self.assertEqual(watcher.state['history'], [])

    def test_disabled_account_is_skipped_on_startup_refresh_start_and_wake(self):
        for action in (None, 'refresh', 'start', 'wake'):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as folder:
                watcher, _ = self.make_watcher(folder, {'profiles': {'account-test': {'enabled': False}}})
                if action == 'wake':
                    watcher.running = True
                if action:
                    watcher.command({'action': action})
                before = list(watcher.state['history'])
                def stop_loop(**kwargs):
                    watcher.closed = True
                with patch.object(pulse, 'read_account') as read, patch.object(watcher.wake, 'wait', side_effect=stop_loop):
                    watcher.run()
                    read.assert_not_called()
                self.assertEqual(watcher.state['history'], before)

    def test_switch_off_cancels_active_check_and_does_not_log_connection_error(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            def disable_and_fail(*args, **kwargs):
                watcher.command({'action': 'toggle', 'id': 'account-test'})
                raise RuntimeError('connection closed after cancellation')
            with patch.object(pulse, 'read_account', side_effect=disable_and_fail):
                watcher.check('account-test', watcher.epoch)
            self.assertFalse(watcher.preference('account-test')['enabled'])
            self.assertTrue(watcher.children.stopping)
            self.assertIsNone(watcher.accounts['account-test']['error'])
            self.assertEqual(watcher.accounts['account-test']['status'], 'İzleme kapalı')
            self.assertFalse(any(e['kind'] in ('check', 'error') for e in watcher.state['history']))

    def test_late_success_from_disabled_account_is_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            def disable_and_return(*args, **kwargs):
                watcher.command({'action': 'toggle', 'id': 'account-test'})
                return {'email': 'fixture@example.com', 'planType': 'plus'}, {'accountId': 'fixture'}, snapshot()
            with patch.object(pulse, 'read_account', side_effect=disable_and_return):
                watcher.check('account-test', watcher.epoch)
            self.assertIsNone(watcher.accounts['account-test']['lastCheckedAt'])
            self.assertFalse(any(e['kind'] == 'check' for e in watcher.state['history']))

    def test_cli_check_respects_disabled_profile_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder, {'profiles': {'account-test': False}})
            args = ['backend.py', '--check', '--root', str(watcher.root), '--state-dir', str(watcher.state_dir)]
            with patch('sys.argv', args), patch.object(pulse, 'codex_executable', return_value='/fake'), \
                 patch.object(pulse, 'read_account') as read, patch('sys.stdout', new_callable=io.StringIO):
                pulse.main()
                read.assert_not_called()

    def test_reenabled_account_can_be_checked_again(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder, {'profiles': {'account-test': {'enabled': False}}})
            watcher.command({'action': 'toggle', 'id': 'account-test'})
            result = ({'email': 'fixture@example.com', 'planType': 'plus'}, {'accountId': 'fixture'}, snapshot())
            with patch.object(pulse, 'read_account', return_value=result) as read:
                watcher.check('account-test', watcher.epoch)
                read.assert_called_once()
            self.assertIsNotNone(watcher.accounts['account-test']['lastCheckedAt'])

    def test_rpc_does_not_send_rate_limit_request_after_switch_is_disabled(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, _ = self.make_watcher(folder)
            root = Path(folder)
            fake = root / 'codex'
            fake.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
for line in sys.stdin:
    req = json.loads(line)
    method = req['method']
    with (Path(os.environ['CODEX_HOME'])/'methods.txt').open('a') as log:
        log.write(method + '\\n')
    if method == 'initialized': continue
    result = {} if method == 'initialize' else {'account': {'type':'chatgpt', 'email':'fixture@example.com', 'planType':'plus'}}
    print(json.dumps({'id':req['id'], 'result':result}), flush=True)
''')
            fake.chmod(0o700)
            watcher.codex = str(fake)
            original_read = pulse.read_account
            def read_and_disable(codex, home, children, on_account, guard):
                def got_account(account):
                    on_account(account)
                    watcher.command({'action': 'toggle', 'id': 'account-test'})
                return original_read(codex, home, children, got_account, guard)
            reaped = []
            original_finish = watcher.children.finish
            def finish_and_verify(process):
                try:
                    original_finish(process)
                finally:
                    reaped.append(process.returncode)
            with patch.object(pulse, 'read_account', side_effect=read_and_disable), \
                 patch.object(watcher.children, 'finish', side_effect=finish_and_verify):
                watcher.check('account-test', watcher.epoch)
            self.assertEqual(len(reaped), 1)
            self.assertIsNotNone(reaped[0])
            methods = (watcher.root/'account-test/methods.txt').read_text().splitlines()
            self.assertIn('account/read', methods)
            self.assertNotIn('account/rateLimits/read', methods)
            self.assertFalse(watcher.children.active)
            self.assertFalse(any(e['kind'] in ('error', 'check') for e in watcher.state['history']))


    def test_language_defaults_to_english_for_new_and_existing_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder, {'settings': {'interval': 47}})
            self.assertEqual(watcher.settings['language'], 'en')
            watcher.publish()
            self.assertEqual(events[-1]['accounts'][0]['label'], 'Codex account 1')
            watcher.command({'action': 'settings', 'settings': {'language': 'tr'}})
            reopened, _ = self.make_watcher(folder)
            self.assertEqual(reopened.settings['language'], 'tr')
            self.assertEqual(reopened.settings['interval'], 47)

    def test_language_change_retranslates_history_without_rewriting_history_or_aliases(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.command({'action': 'profile', 'id': 'account-test', 'settings': {'alias': 'Başlat'}})
            watcher.event('check', 'Limit durumu okundu · Limit dolu · yenilenme bekleniyor', 'account-test')
            watcher.publish()
            self.assertEqual(events[-1]['history'][0]['message'], 'Usage limits checked · Limit reached · waiting for reset')
            self.assertEqual(events[-1]['accounts'][0]['alias'], 'Başlat')
            original = watcher.state['history'][-1]['message']
            watcher.command({'action': 'settings', 'settings': {'language': 'tr'}})
            self.assertEqual(events[-1]['history'][1]['message'], original)
            self.assertEqual(watcher.state['history'][-2]['message'], original)
            self.assertEqual(events[-1]['accounts'][0]['alias'], 'Başlat')

    def test_invalid_language_is_rejected_without_overwriting_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.command({'action': 'settings', 'requestId': 'bad-language', 'settings': {'language': 'de'}})
            self.assertEqual(watcher.settings['language'], 'en')
            self.assertFalse(events[-1]['commandResult']['ok'])
            self.assertEqual(events[-1]['commandError'], 'Invalid language selection.')

    def test_notification_body_follows_language_but_nickname_is_never_translated(self):
        with tempfile.TemporaryDirectory() as folder:
            watcher, events = self.make_watcher(folder)
            watcher.command({'action': 'settings', 'settings': {'notificationsEnabled': True}})
            watcher.command({'action': 'profile', 'id': 'account-test', 'settings': {'alias': 'Başlat'}})
            watcher.event('success', 'Kısa sorgu tamamlandı', 'account-test', notify=True)
            self.assertEqual(events[-1]['notification']['body'], 'Short prompt completed')
            self.assertEqual(events[-1]['notification']['title'], 'Başlat')
            watcher.command({'action': 'settings', 'settings': {'language': 'tr'}})
            watcher.event('success', 'Kısa sorgu tamamlandı', 'account-test', notify=True)
            self.assertEqual(events[-1]['notification']['body'], 'Kısa sorgu tamamlandı')

    def test_catalog_covers_static_native_interface_strings_and_format_placeholders(self):
        import re
        root = Path(__file__).parents[1]
        source = (root/'App.swift').read_text()
        keys = re.findall(r'(?:model\.)?(?:tr|fmt)\("([^"\\]*)"', source)
        for key in keys:
            self.assertIn(key, pulse.ENGLISH, key)
        for original, translated in pulse.ENGLISH.items():
            self.assertEqual(set(re.findall(r'\{(\w+)\}',original)), set(re.findall(r'\{(\w+)\}',translated)), original)
        self.assertEqual(pulse.localize('5 saatlik limit'), '5-hour limit')
        self.assertEqual(pulse.localize('Haftalık limit'), 'Weekly limit')


if __name__ == '__main__':
    unittest.main()
