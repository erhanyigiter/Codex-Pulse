#!/usr/bin/env python3
"""Local menu-bar companion. Uses each existing Monocode CODEX_HOME in place.

No tokens are read, exported or copied by this program. Codex manages its own auth.
Only explicit Start enables model requests; status reads do not create model turns.
"""
import argparse
from datetime import datetime, timedelta
from contextlib import contextmanager, nullcontext
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

APP_NAME = 'Codex Pulse'
DEFAULT_ROOT = Path.home() / 'Library/Application Support/com.monocode.desktop/provider-accounts/codex'
DEFAULT_HOME = Path.home() / '.codex'
DEFAULT_STATE = Path.home() / 'Library/Application Support/Codex Pulse'
GRACE = 15
MAX_HISTORY = 300
ENGLISH = json.loads(Path(__file__).with_name('Localizations.json').read_text())['en']


def localize(text, language='en'):
    if text is None or language == 'tr':
        return text
    if text in ENGLISH:
        return ENGLISH[text]
    if text.startswith('Codex hesabı '):
        return 'Codex account ' + text.removeprefix('Codex hesabı ')
    prefix = 'Limit durumu okundu · '
    if text.startswith(prefix):
        return ENGLISH['Limit durumu okundu'] + ' · ' + localize(text[len(prefix):], language)
    if ' · ' in text:
        return ' · '.join(localize(part, language) for part in text.split(' · '))
    return text


DEFAULT_SETTINGS = {
    'language': 'en',
    'mode': 'reset', 'interval': 30, 'retryInterval': 5,
    'notificationsEnabled': False, 'autoStart': False, 'selectedAccountId': '',
    'quietEnabled': False, 'quietStart': '23:00', 'quietEnd': '08:00',
}


def minutes(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 10080:
        raise ValueError('Dakika değeri 1 ile 10080 arasında tam sayı olmalı.')
    return value


def clock_minutes(value):
    if not isinstance(value, str) or len(value) != 5 or value[2] != ':':
        raise ValueError('Saat HH:MM biçiminde olmalı.')
    try:
        hour, minute = int(value[:2]), int(value[3:])
    except ValueError:
        raise ValueError('Saat HH:MM biçiminde olmalı.')
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ValueError('Geçerli bir saat girin: 00:00–23:59.')
    return hour * 60 + minute


def validate_settings(settings):
    result = {**DEFAULT_SETTINGS, **settings}
    if result['language'] not in ('en', 'tr'):
        raise ValueError('Geçersiz dil seçimi.')
    if result['mode'] not in ('reset', 'periodic'):
        raise ValueError('Geçersiz kontrol modu.')
    for key in ('interval', 'retryInterval'):
        minutes(result[key])
    for key in ('notificationsEnabled', 'autoStart', 'quietEnabled'):
        if not isinstance(result[key], bool):
            raise ValueError('Ayar değeri geçersiz.')
    start, end = clock_minutes(result['quietStart']), clock_minutes(result['quietEnd'])
    if start == end:
        raise ValueError('Sessiz saatlerin başlangıcı ve bitişi farklı olmalı.')
    if not isinstance(result['selectedAccountId'], str):
        raise ValueError('Geçersiz hesap seçimi.')
    return {key: result[key] for key in DEFAULT_SETTINGS}


def profile_settings(settings, profile):
    result = dict(settings)
    if profile.get('overrideEnabled'):
        for key in ('mode', 'interval', 'retryInterval'):
            result[key] = profile[key]
    return result


def quiet_until(now, settings):
    if not settings.get('quietEnabled'):
        return None
    start, end = clock_minutes(settings['quietStart']), clock_minutes(settings['quietEnd'])
    local = datetime.fromtimestamp(now)
    current = local.hour * 60 + local.minute
    active = start <= current < end if start < end else current >= start or current < end
    if not active:
        return None
    until = local.replace(hour=end // 60, minute=end % 60, second=0, microsecond=0)
    if start > end and current >= start:
        until += timedelta(days=1)
    return until.timestamp()


def short_window(snapshot):
    return next((w for w in (snapshot.get('primary'), snapshot.get('secondary'))
                 if w and w.get('windowDurationMins') == 300), None)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def eligible(snapshot):
    if snapshot.get('ordinaryUsageAllowed') is not True:
        return False, 'Sunucu kullanım izni bekleniyor'
    if snapshot.get('spendControlReached') is True or snapshot.get('rateLimitReachedType'):
        return False, 'Hesap kullanım sınırında'
    for window in (snapshot.get('primary'), snapshot.get('secondary')):
        if window and (not finite(window.get('usedPercent')) or window['usedPercent'] >= 100):
            return False, 'Limit dolu · yenilenme bekleniyor'
    return True, ''


def decide(snapshot, record, now):
    """Mutate only a journal record, and return the reset eligible for one attempt."""
    window = short_window(snapshot)
    if not window or not finite(window.get('resetsAt')):
        return None, '5 saatlik pencere bilgisi yok'
    reset = window['resetsAt']
    if 'target' not in record:
        record['target'] = reset
        return None, 'Yenilenme izleniyor'
    target = record['target']
    if now < target + GRACE:
        return None, 'Yenilenme izleniyor'
    allowed, reason = eligible(snapshot)
    if not allowed:
        return None, reason
    if reset <= target and window.get('usedPercent') != 0:
        return None, 'Sunucu yenilenmeyi henüz doğrulamadı'
    if record.get('attempted') == target:
        if reset > target:
            record['target'] = reset
        return None, 'Bu pencere için sorgu zaten denendi'
    return target, 'Yeni pencere açıldı'


def next_check(now, settings, snapshot, record):
    retry = now + settings['retryInterval'] * 60
    quiet = quiet_until(now, settings)
    # A full weekly window cannot be helped by repeatedly checking the short one.
    weekly = [w['resetsAt'] + GRACE for w in (snapshot.get('primary'), snapshot.get('secondary'))
              if w and (w.get('windowDurationMins') or 0) >= 10080
              and finite(w.get('usedPercent')) and w['usedPercent'] >= 100
              and finite(w.get('resetsAt')) and w['resetsAt'] + GRACE > now]
    if weekly:
        due = max(weekly)
    else:
        window = short_window(snapshot)
        target = record.get('target', window.get('resetsAt') if window else None)
        if not finite(target) or target + GRACE <= now:
            due = retry
        else:
            due = target + GRACE
            if settings['mode'] == 'periodic':
                due = min(now + settings['interval'] * 60, due)
    return max(due, quiet) if quiet is not None else due


def identity(account, response):
    email = account.get('email')
    account_id = response.get('accountId')
    if not email or not account_id:
        return None
    return hashlib.sha256((email.lower() + '\0' + account_id).encode()).hexdigest()


def discover(root):
    homes = [p for p in sorted(root.glob('account-*'))
             if p.is_dir() and (p / 'auth.json').is_file()]
    if root == DEFAULT_ROOT and (DEFAULT_HOME / 'auth.json').is_file():
        homes.insert(0, DEFAULT_HOME)
    return list({p.resolve(): p for p in homes}.values())


def codex_executable():
    candidates = [Path.home() / '.local/bin/codex', Path('/opt/homebrew/bin/codex'),
                  Path('/usr/local/bin/codex')]
    on_path = shutil.which('codex')
    if on_path:
        candidates.insert(0, Path(on_path))
    return next((str(p) for p in candidates if p.is_file() and os.access(p, os.X_OK)), None)


def child_env(home):
    env = dict(os.environ)
    # Never silently use a paid API key or switch another app's selected account.
    for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL', 'ACCESS_TOKEN'):
        env.pop(key, None)
    env['CODEX_HOME'] = str(home)
    env['NO_COLOR'] = '1'
    return env


class Cancelled(Exception):
    pass


def signal_child(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Some restricted macOS environments deny group signals after a race.
        # Target the child PID instead; Popen checks/reaps an already-exited child.
        process.send_signal(sig)


class Children:
    def __init__(self):
        self.lock = threading.RLock()
        self.active = set()
        self.stopping = False

    def launch(self, command, home, folder):
        with self.lock:
            if self.stopping:
                raise Cancelled()
            process = subprocess.Popen(command, cwd=folder, env=child_env(home),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True, start_new_session=True)
            self.active.add(process)
            return process

    def finish(self, process):
        try:
            if process.poll() is None:
                signal_child(process, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    signal_child(process, signal.SIGKILL)
                    process.wait(timeout=2)
        except ProcessLookupError:
            process.wait(timeout=2)
        finally:
            with self.lock:
                self.active.discard(process)
            for pipe in (process.stdin, process.stdout):
                if pipe:
                    pipe.close()

    def cancel_all(self):
        with self.lock:
            self.stopping = True
            for process in list(self.active):
                try:
                    signal_child(process, signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def resume(self):
        with self.lock:
            self.stopping = False


def read_account(codex, home, children, on_account=None, guard=nullcontext):
    with tempfile.TemporaryDirectory(prefix='codex-pulse-check-') as folder:
        with guard():
            process = children.launch([codex, 'app-server', '--stdio'], home, folder)
        messages = queue.Queue()

        def reader():
            try:
                for line in process.stdout:
                    try:
                        messages.put(json.loads(line))
                    except ValueError:
                        continue
            except (ValueError, OSError):
                pass
            finally:
                messages.put(None)

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()

        def request(number, method, params):
            with guard():
                process.stdin.write(json.dumps({'id': number, 'method': method, 'params': params}) + '\n')
                process.stdin.flush()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                try:
                    message = messages.get(timeout=min(0.5, max(0.01, deadline - time.monotonic())))
                except queue.Empty:
                    continue
                if message is None:
                    raise RuntimeError('Codex bağlantısı kapandı')
                if message.get('id') == number:
                    if 'error' in message:
                        raise RuntimeError('Oturum veya bağlantı doğrulanamadı')
                    return message['result']
            raise RuntimeError('Codex yanıtı zaman aşımına uğradı')

        try:
            request(1, 'initialize', {'clientInfo': {'name': 'codex_pulse', 'title': APP_NAME,
                                                    'version': '1.3.2'}, 'capabilities': None})
            with guard():
                process.stdin.write('{"method":"initialized"}\n')
                process.stdin.flush()
            account = request(2, 'account/read', {'refreshToken': False}).get('account')
            if not account or account.get('type') != 'chatgpt':
                raise RuntimeError('Bu profilde ChatGPT oturumu yok; Monocode’dan giriş yapın')
            if on_account:
                on_account(account)
            limits = request(3, 'account/rateLimits/read', None)
            buckets = limits.get('rateLimitsByLimitId') or {}
            snapshot = dict(buckets.get('codex') or limits['rateLimits'])
            snapshot['ordinaryUsageAllowed'] = limits.get('ordinaryUsageAllowed')
            return account, limits, snapshot
        finally:
            children.finish(process)
            thread.join(timeout=1)


def send_prompt(codex, home, children, launch=None):
    with tempfile.TemporaryDirectory(prefix='codex-pulse-prompt-') as folder:
        command = [codex, 'exec', '--ignore-user-config', '--sandbox', 'read-only',
                   '--skip-git-repo-check', '--ephemeral', '--color', 'never', '--cd', folder,
                   'Araç kullanma ve dosya okuma. Sadece OK yaz.']
        process = (launch or children.launch)(command, home, folder)
        try:
            process.communicate(timeout=120)
            return process.returncode == 0
        except subprocess.TimeoutExpired:
            return False
        finally:
            children.finish(process)


class Watcher:
    def __init__(self, root, state_dir, emit, force_paused=False):
        self.root, self.state_dir, self.emit = root, state_dir, emit
        self.lock = threading.RLock()
        self.children = Children()
        self.wake = threading.Event()
        self.closed = False
        self.epoch = 0
        self.refresh = True
        self.status_only = False
        self.active_id = None
        self.next_scan = 0
        self.accounts = {}
        self.cached = {}
        self.codex = codex_executable()
        self.path = state_dir / 'state.json'
        self.state = {'version': 2, 'settings': dict(DEFAULT_SETTINGS), 'profiles': {},
                      'journal': {}, 'history': [], 'accountOrder': []}
        if self.path.exists():
            loaded = json.loads(self.path.read_text())
            if not isinstance(loaded, dict) or not isinstance(loaded.get('journal', {}), dict):
                raise ValueError('Yerel ayar dosyası geçersiz; işlem kaydı korunarak kontrol edilmeli.')
            order = loaded.get('accountOrder', [])
            self.state['accountOrder'] = list(dict.fromkeys(k for k in order if isinstance(k, str))) if isinstance(order, list) else []
            self.state['journal'] = loaded.get('journal', {})
            self.state['history'] = loaded.get('history', [])[-MAX_HISTORY:]
            # v1 boolean account switches and its custom interval are preserved.
            for key, value in loaded.get('profiles', {}).items():
                self.state['profiles'][key] = ({'enabled': value} if isinstance(value, bool) else value)
            old_interval = loaded.get('interval', 30)
            base = {**DEFAULT_SETTINGS, 'interval': old_interval}
            self.state['settings'] = validate_settings({**base, **loaded.get('settings', {})})
        self.running = self.state['settings']['autoStart'] and not force_paused
        self.error = None if self.codex else 'Codex CLI bulunamadı. Önce Codex CLI kurulumunu tamamlayın.'
        self.command_error = None
        self.command_result = None
        self.rescan()

    @property
    def settings(self):
        return self.state['settings']

    def preference(self, key):
        return self.state['profiles'].setdefault(key, {'enabled': True})

    def effective(self, key):
        return profile_settings(self.settings, self.preference(key))

    def save(self):
        temporary = self.path.with_suffix('.tmp')
        fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(self.state, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, self.path)

    def event(self, kind, message, key=None, notify=False):
        entry = {'id': str(uuid.uuid4()), 'at': time.time(), 'kind': kind,
                 'message': message, 'accountId': key}
        self.state['history'].append(entry)
        self.state['history'] = self.state['history'][-MAX_HISTORY:]
        self.save()
        if notify and self.settings['notificationsEnabled'] and quiet_until(time.time(), self.settings) is None:
            alias = self.preference(key).get('alias') if key else None
            self.publish({'id': entry['id'], 'title': alias or APP_NAME, 'body': message})

    def rescan(self):
        valid = set()
        self.homes = {}
        for index, home in enumerate(discover(self.root)):
            key = 'default' if home.resolve() == DEFAULT_HOME.resolve() else home.name
            self.homes[key] = home
            valid.add(key)
            pref = self.preference(key)
            if key not in self.accounts:
                self.accounts[key] = {'id': key, 'label': 'Codex hesabı ' + str(index + 1),
                                      'plan': '', 'status': 'Durum okunuyor' if pref.get('enabled', True) else 'İzleme kapalı', 'nextCheckAt': 0,
                                      'enabled': pref.get('enabled', True), 'alias': pref.get('alias', ''),
                                      'usedPercent': None, 'weeklyUsedPercent': None,
                                      'resetsAt': None, 'weeklyResetsAt': None, 'lastCheckedAt': None,
                                      'lastTriggeredAt': None, 'error': None}
        self.accounts = {k: v for k, v in self.accounts.items() if k in valid}
        self.cached = {k: v for k, v in self.cached.items() if k in valid}

    def ordered_ids(self):
        saved = self.state['accountOrder']
        return [key for key in saved if key in self.accounts] + [
            key for key in self.accounts if key not in saved]

    def visible_ids(self):
        # Prefer dedicated profiles over the mutable default CODEX_HOME.
        representatives = {}
        for key in sorted(self.accounts, key=lambda key: key == 'default'):
            owner = self.cached.get(key, {}).get('owner')
            if owner:
                representatives.setdefault(owner, key)
        result = []
        for key in self.ordered_ids():
            owner = self.cached.get(key, {}).get('owner')
            representative = representatives.get(owner, key)
            if representative not in result:
                result.append(representative)
        return result

    def publish(self, notification=None):
        with self.lock:
            rows = []
            for key in self.visible_ids():
                account = self.accounts[key]
                pref = self.preference(key)
                row = dict(account)
                row['alias'] = pref.get('alias', '')
                row['enabled'] = pref.get('enabled', True)
                row['overrideEnabled'] = pref.get('overrideEnabled', False)
                row['mode'] = pref.get('mode', self.settings['mode'])
                row['interval'] = pref.get('interval', self.settings['interval'])
                row['retryInterval'] = pref.get('retryInterval', self.settings['retryInterval'])
                for field in ('label', 'status', 'error'):
                    row[field] = localize(row.get(field), self.settings['language'])
                rows.append(row)
            history = [{**entry, 'message': localize(entry['message'], self.settings['language'])}
                       for entry in reversed(self.state['history'])]
            result = ({**self.command_result, 'message': localize(self.command_result.get('message'), self.settings['language'])}
                      if self.command_result else None)
            notice = ({**notification, 'body': localize(notification['body'], self.settings['language'])}
                      if notification else None)
            self.emit({'running': self.running, 'settings': dict(self.settings), 'accounts': rows,
                       'error': localize(self.error, self.settings['language']),
                       'commandError': localize(self.command_error, self.settings['language']),
                       'commandResult': result,
                       'activeId': self.active_id, 'history': history,
                       'notification': notice,
                       'quietUntil': quiet_until(time.time(), self.settings)})

    def reschedule(self):
        now = time.time()
        for key, account in self.accounts.items():
            cached = self.cached.get(key)
            if cached:
                record = self.state['journal'].get(cached['owner'], {})
                account['nextCheckAt'] = next_check(now, self.effective(key), cached['snapshot'], record)
            else:
                account['nextCheckAt'] = now

    def command(self, command):
        with self.lock:
            request_id = command.get('requestId')
            self.command_result = None
            succeeded = True
            try:
                self.command_error = None
                action = command.get('action')
                if action in ('pause', 'quit'):
                    was_running = self.running
                    self.running = False
                    self.epoch += 1
                    self.children.cancel_all()
                    if action == 'quit':
                        self.closed = True
                    if was_running or action == 'pause':
                        self.event('pause', 'İzleme durduruldu' if action == 'pause' else 'Uygulama kapatıldı')
                elif action == 'start':
                    self.children.resume()
                    self.running = True
                    self.epoch += 1
                    self.refresh = True
                    self.status_only = False
                    self.event('start', 'İzleme başlatıldı')
                elif action == 'refresh':
                    self.children.resume()
                    self.refresh = True
                    self.status_only = True  # Manual refresh reads status, never sends a turn.
                elif action == 'wake':
                    if self.running:
                        self.children.resume()
                        self.refresh = True
                        self.status_only = False
                elif action == 'settings':
                    patch = command.get('settings', {})
                    if not isinstance(patch, dict) or any(k not in DEFAULT_SETTINGS for k in patch):
                        raise ValueError('Geçersiz ayar.')
                    self.state['settings'] = validate_settings({**self.settings, **patch})
                    # Settings don't perform network reads. Pending automatic checks are recomputed.
                    self.epoch += 1
                    self.reschedule()
                    self.event('settings', 'Genel ayarlar kaydedildi')
                elif action == 'profile' and command.get('id') in self.accounts:
                    key = command['id']
                    pref = dict(self.preference(key))
                    values = command.get('settings', {})
                    if not isinstance(values, dict):
                        raise ValueError('Geçersiz hesap ayarı.')
                    alias = values.get('alias', pref.get('alias', ''))
                    if not isinstance(alias, str) or len(alias.strip()) > 60 or any(ord(c) < 32 for c in alias):
                        raise ValueError('Hesap adı en fazla 60 karakter olmalı.')
                    override = values.get('overrideEnabled', pref.get('overrideEnabled', False))
                    if not isinstance(override, bool):
                        raise ValueError('Geçersiz hesap ayarı.')
                    pref.update(alias=alias.strip(), overrideEnabled=override)
                    if override:
                        mode = values.get('mode', pref.get('mode', self.settings['mode']))
                        if mode not in ('reset', 'periodic'):
                            raise ValueError('Geçersiz kontrol modu.')
                        pref.update(mode=mode, interval=minutes(values.get('interval', pref.get('interval', self.settings['interval']))),
                                    retryInterval=minutes(values.get('retryInterval', pref.get('retryInterval', self.settings['retryInterval']))))
                    self.state['profiles'][key] = pref
                    self.epoch += 1
                    self.reschedule()
                    self.event('settings', 'Hesap ayarları kaydedildi', key)
                elif action == 'toggle' and command.get('id') in self.accounts:
                    key = command['id']
                    account = self.accounts[key]
                    pref = self.preference(key)
                    pref['enabled'] = not pref.get('enabled', True)
                    account['enabled'] = pref['enabled']
                    self.epoch += 1
                    if not pref['enabled'] and self.active_id == key:
                        self.children.cancel_all()
                    if pref['enabled']:
                        account['nextCheckAt'] = time.time()
                    else:
                        account['error'] = None
                        account['status'] = 'İzleme kapalı'
                    self.event('settings', 'Hesap izlemeye açıldı' if pref['enabled'] else 'Hesap izleme kapatıldı', key)
                elif action == 'moveAccount':
                    source, target = command.get('id'), command.get('targetId')
                    if not isinstance(source, str) or not isinstance(target, str) or source not in self.accounts or target not in self.accounts:
                        raise ValueError('Geçersiz hesap seçimi.')
                    order = self.ordered_ids()
                    destination = order.index(target)
                    order.remove(source)
                    order.insert(destination, source)
                    self.state['accountOrder'] = order
                    self.save()
                elif action == 'clearHistory':
                    self.state['history'] = []  # Never clear the at-most-once journal.
                    self.save()
                else:
                    raise ValueError('Komut tanınmadı.')
            except (ValueError, TypeError) as error:
                succeeded = False
                self.command_error = str(error)
            except OSError:
                succeeded = False
                self.running = False
                self.epoch += 1
                self.children.cancel_all()
                self.error = 'Yerel kayıt yazılamadı. İzleme durduruldu; disk alanını kontrol edin.'
            if isinstance(request_id, str) and len(request_id) <= 100:
                self.command_result = {'id': request_id, 'ok': succeeded,
                                       'message': None if succeeded else self.command_error or self.error}
            self.wake.set()
            self.publish()

    def check(self, key, epoch, allow_trigger=True):
        account_view = self.accounts[key]
        with self.lock:
            if self.closed or epoch != self.epoch or not self.preference(key).get('enabled', True):
                return
            self.children.resume()
            self.active_id = key
            self.publish()
        try:
            home = self.homes[key]
            @contextmanager
            def check_enabled():
                with self.lock:
                    if self.closed or epoch != self.epoch or not self.preference(key).get('enabled', True):
                        raise Cancelled()
                    yield

            def account_found(account):
                with check_enabled():
                    account_view['label'] = account.get('email') or account_view['label']
                    account_view['plan'] = account.get('planType') or ''
                    self.publish()

            account, response, snapshot = read_account(self.codex, home, self.children, account_found, guard=check_enabled)
            now = time.time()
            owner = identity(account, response)
            window = short_window(snapshot)
            weekly = next((w for w in (snapshot.get('primary'), snapshot.get('secondary'))
                           if w and (w.get('windowDurationMins') or 0) >= 10080), None)
            with self.lock:
                if self.closed or epoch != self.epoch or not self.preference(key).get('enabled', True):
                    return
                account_view.update(label=account.get('email') or account_view['label'],
                                    plan=account.get('planType') or '', lastCheckedAt=now,
                                    usedPercent=window.get('usedPercent') if window else None,
                                    weeklyUsedPercent=weekly.get('usedPercent') if weekly else None,
                                    resetsAt=window.get('resetsAt') if window else None,
                                    weeklyResetsAt=weekly.get('resetsAt') if weekly else None, error=None)
                if not owner:
                    account_view['status'] = 'Hesap kimliği doğrulanamadı; sorgu gönderilmez'
                    account_view['nextCheckAt'] = now + self.effective(key)['retryInterval'] * 60
                    self.event('warning', 'Hesap kimliği doğrulanamadı; sorgu gönderilmedi', key)
                    return
                self.cached[key] = {'owner': owner, 'snapshot': snapshot}
                record = self.state['journal'].setdefault(owner, {})
                trigger, reason = decide(snapshot, record, now)
                if weekly and finite(weekly.get('usedPercent')) and weekly['usedPercent'] >= 100:
                    reason = 'Haftalık limit dolu · yenilenme bekleniyor'
                account_view['status'] = reason
                account_view['lastTriggeredAt'] = record.get('lastSuccess')
                settings = self.effective(key)
                account_view['nextCheckAt'] = next_check(now, settings, snapshot, record)
                self.event('check', 'Limit durumu okundu · ' + reason, key)
                automatic = (allow_trigger and self.running and self.preference(key).get('enabled', True)
                             and epoch == self.epoch)
                if not automatic or trigger is None:
                    return
                quiet = quiet_until(now, settings)
                if quiet is not None:
                    account_view['status'] = 'Sessiz saatler · sorgu ertelendi'
                    account_view['nextCheckAt'] = quiet
                    self.event('deferred', 'Sessiz saatler nedeniyle sorgu ertelendi', key)
                    return
                # At-most-once, persisted BEFORE any model request; aliases share this identity.
                record['attempted'] = trigger
                record['lastAttempt'] = now
                if window['resetsAt'] > trigger:
                    record['target'] = window['resetsAt']
                self.event('attempt', 'Yeni pencere doğrulandı; kısa sorgu başlatılıyor', key)
                account_view['status'] = 'Kısa sorgu gönderiliyor'
                self.publish()

            def authorized_launch(command, profile, folder):
                with self.lock:
                    if (not self.running or epoch != self.epoch or not self.preference(key).get('enabled', True)
                            or quiet_until(time.time(), self.effective(key)) is not None):
                        raise Cancelled()
                    return self.children.launch(command, profile, folder)

            success = send_prompt(self.codex, home, self.children, authorized_launch)
            with self.lock:
                now = time.time()
                if epoch != self.epoch or not self.running:
                    account_view['status'] = 'İşlem durduruldu'
                    self.event('cancelled', 'Sorgu durduruldu; bu pencere için tekrar gönderilmeyecek', key)
                elif success:
                    record['lastSuccess'] = now
                    account_view['lastTriggeredAt'] = now
                    account_view['status'] = 'Tamamlandı · sonraki pencere bekleniyor'
                    self.event('success', 'Kısa sorgu tamamlandı', key, notify=True)
                else:
                    account_view['status'] = 'Sorgu başarısız · otomatik tekrar yok'
                    account_view['error'] = 'Monocode oturumunu ve Codex erişimini kontrol edin.'
                    self.event('error', 'Sorgu tamamlanamadı; bu pencere için tekrar gönderilmeyecek', key, notify=True)
                account_view['nextCheckAt'] = next_check(now, self.effective(key), snapshot, record)
        except Cancelled:
            with self.lock:
                if self.preference(key).get('enabled', True):
                    account_view['status'] = 'İşlem durduruldu'
                    self.event('cancelled', 'İşlem durduruldu', key)
                else:
                    account_view['status'] = 'İzleme kapalı'
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError):
            with self.lock:
                if not self.preference(key).get('enabled', True):
                    account_view['status'] = 'İzleme kapalı'
                elif self.closed or epoch != self.epoch:
                    account_view['status'] = 'İşlem durduruldu'
                else:
                    changed = account_view['error'] is None
                    account_view['error'] = 'Monocode oturumunu ve internet bağlantısını kontrol edin.'
                    account_view['status'] = 'Durum okunamadı'
                    self.event('error', 'Limit okunamadı; oturum veya bağlantıyı kontrol edin', key, notify=changed)
                account_view['nextCheckAt'] = time.time() + self.effective(key)['retryInterval'] * 60
        finally:
            with self.lock:
                self.active_id = None
                self.publish()

    def run(self):
        self.publish()
        while not self.closed:
            with self.lock:
                refresh, status_only = self.refresh, self.status_only
                self.refresh = self.status_only = False
                if refresh or (self.running and time.time() >= self.next_scan):
                    self.rescan()
                    self.next_scan = time.time() + 60  # Local folder discovery only; no network.
                epoch = self.epoch
                due = [k for k, a in self.accounts.items()
                       if self.preference(k).get('enabled', True)
                       and (refresh or (self.running and a['nextCheckAt'] <= time.time()))]
            if self.codex:
                for key in due:
                    if self.closed or epoch != self.epoch:
                        break
                    self.check(key, epoch, allow_trigger=not status_only)
            with self.lock:
                deadlines = [a['nextCheckAt'] for k, a in self.accounts.items()
                             if self.running and self.preference(k).get('enabled', True)]
                timeout = max(0.1, min(60, min(deadlines) - time.time())) if deadlines else 60
            self.wake.wait(timeout=timeout)
            self.wake.clear()
        self.children.cancel_all()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--state-dir', type=Path, default=DEFAULT_STATE)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--paused', action='store_true', help='Override saved auto-start for this launch.')
    args = parser.parse_args()
    os.umask(0o077)
    if args.check:
        codex = codex_executable()
        if not codex:
            raise SystemExit(localize('Codex CLI bulunamadı'))
        try:
            prefs = json.loads((args.state_dir / 'state.json').read_text()).get('profiles', {}) if (args.state_dir / 'state.json').exists() else {}
        except (OSError, ValueError, TypeError):
            raise SystemExit('Yerel hesap ayarları okunamadı; hiçbir hesap sorgulanmadı.')
        for home in discover(args.root):
            key = 'default' if home.resolve() == DEFAULT_HOME.resolve() else home.name
            pref = prefs.get(key, {})
            if pref is False or (isinstance(pref, dict) and not pref.get('enabled', True)):
                continue
            try:
                account, response, snapshot = read_account(codex, home, Children())
                print(json.dumps({'profile': home.name, 'plan': account.get('planType'),
                                  'identityConfirmed': bool(identity(account, response)),
                                  'primary': snapshot.get('primary'), 'secondary': snapshot.get('secondary'),
                                  'usageAllowed': snapshot.get('ordinaryUsageAllowed')}, ensure_ascii=False))
            except (RuntimeError, OSError, ValueError):
                print(json.dumps({'profile': home.name, 'error': 'Oturum veya bağlantı doğrulanamadı'}))
        return
    args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lockfile = (args.state_dir / 'watcher.lock').open('a')
    try:
        fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(localize('Codex Pulse zaten açık.'))
    output_lock = threading.Lock()

    def emit(event):
        with output_lock:
            print(json.dumps(event, ensure_ascii=False), flush=True)

    try:
        watcher = Watcher(args.root, args.state_dir, emit, force_paused=args.paused)
    except (ValueError, OSError, TypeError, KeyError):
        print(json.dumps({'running': False, 'settings': DEFAULT_SETTINGS, 'accounts': [],
                          'history': [], 'activeId': None, 'commandError': None,
                          'notification': None, 'quietUntil': None,
                          'error': localize('Yerel ayarlar okunamadı. İşlem kayıtlarını silmeden state.json dosyasını kontrol edin.')}), flush=True)
        return
    signal.signal(signal.SIGTERM, lambda *_: watcher.command({'action': 'quit'}))

    def commands():
        try:
            for line in sys.stdin:
                try:
                    watcher.command(json.loads(line))
                except (ValueError, TypeError):
                    continue
        finally:
            watcher.command({'action': 'quit'})

    threading.Thread(target=commands, daemon=True).start()
    try:
        watcher.run()
    finally:
        watcher.children.cancel_all()


if __name__ == '__main__':
    main()
