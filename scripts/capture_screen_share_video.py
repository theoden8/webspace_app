#!/usr/bin/env python3
"""Record a real release APK from outside Android's MediaProjection session."""

import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/screen-share-video'
APK = ROOT / 'build/app/outputs/flutter-apk/app-fdroid-release.apk'
PAGE = ROOT / 'tool/screen_share_demo/index.html'
APP = 'org.codeberg.theoden8.webspace'
PORT = 8765
EVENTS = []
EVENT_LOCK = threading.Lock()
ADB = ['adb'] + (['-s', os.environ['ANDROID_SERIAL']] if os.getenv('ANDROID_SERIAL') else [])


def run(*args, timeout=30):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout).stdout


def adb(*args, timeout=30):
    return run(*ADB, *args, timeout=timeout).decode().strip()


def console(*args):
    answer = adb('emu', *args)
    if re.search(r'^KO:', answer, re.MULTILINE):
        raise RuntimeError(answer)
    return answer


class DemoServer(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.read_bytes() if self.path == '/' else b''
        self.send_response(200 if body else 404)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/event':
            self.send_error(404)
            return
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size < 16384:
            self.send_error(400)
            return
        event = json.loads(self.rfile.read(size))
        event['time'] = time.time()
        with EVENT_LOCK:
            EVENTS.append(event)
            (OUT / 'events.json').write_text(json.dumps(EVENTS, indent=2) + '\n')
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_args):
        pass


def ui():
    adb('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/ws_capture_ui.xml')
    raw = adb('shell', 'cat', '/sdcard/ws_capture_ui.xml')
    (OUT / 'latest-ui.xml').write_text(raw)
    return ET.fromstring(raw)


def labelled(tree, labels):
    wanted = {label.casefold() for label in labels}
    return [node for node in tree.iter('node')
            if node.get('enabled') != 'false'
            and any(part.casefold() in wanted
                    for attr in ('text', 'content-desc')
                    for part in node.get(attr, '').split('\n'))]


def wait_node(labels, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        tree = ui()
        if labelled(tree, ["System UI isn't responding"]):
            tap(labelled(tree, ['Wait'])[-1])
            time.sleep(3)
            continue
        found = labelled(tree, labels)
        if found:
            return found[-1]
        time.sleep(1)
    raise RuntimeError(f'No visible control: {labels}; see latest-ui.xml')


def tap(node):
    left, top, right, bottom = map(int, re.findall(r'\d+', node.get('bounds', '')))
    if right <= left or bottom <= top:
        raise RuntimeError(f'Control has empty bounds: {node.attrib}')
    adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))


def tap_label(*labels):
    tap(wait_node(labels))


def evidence(name):
    print(name, flush=True)
    (OUT / f'{name}.png').write_bytes(run(*ADB, 'exec-out', 'screencap', '-p'))
    (OUT / f'{name}.xml').write_text(ET.tostring(ui(), encoding='unicode'))


def wait_event(kind, *, moving=False, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with EVENT_LOCK:
            events = list(EVENTS)
        for event in events:
            if event['event'] == 'error':
                raise RuntimeError(f'Demo failed: {event}')
            if event['event'] == kind:
                if not moving or (event['frames'] >= 20 and event['changed'] >= 5):
                    return event
        time.sleep(.5)
    raise RuntimeError(f'Demo never reported {kind}, moving={moving}')


def walkthrough():
    adb('shell', 'am', 'start', '-W', '-n', f'{APP}/.MainActivity')
    node = wait_node(['Add', 'Add Site'], timeout=90)
    time.sleep(3)
    evidence('01-webspace')
    tap(node)
    tree = ui()
    if not any(n.get('class') == 'android.widget.EditText' for n in tree.iter('node')):
        tap_label('Add Site')
    field = wait_node(['Enter URL'])
    tap(field)
    adb('shell', 'input', 'text', f'http://localhost:{PORT}/')
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    time.sleep(2)
    tap_label('Add Site')
    ready = wait_event('ready')
    if not ready['supported']:
        raise RuntimeError('The page cannot reach getDisplayMedia in this build')
    evidence('02-demo-page')
    time.sleep(3)
    tap_label('Start sharing')
    wait_node(['Allow screen sharing?'])
    evidence('03-webspace-disclosure')
    time.sleep(7)
    tap_label('Allow')

    # Android 14+ defaults to sharing one app. Pick the entire screen in the
    # real system dialog so the review can also show the notification shade.
    wait_node(['A single app', 'Single app', 'Entire screen', 'Start now'])
    tree = ui()
    choices = labelled(tree, ['A single app', 'Single app'])
    if choices:
        tap(choices[-1])
        tap_label('Entire screen')
    evidence('04-android-consent')
    time.sleep(5)
    tap_label('Start now', 'Start sharing', 'Share screen', 'Share')
    wait_event('started')
    wait_event('frames', moving=True)
    projection = adb('shell', 'dumpsys', 'media_projection')
    (OUT / 'projection-active.txt').write_text(projection)
    if APP not in projection:
        raise RuntimeError('The real MediaProjection session is not owned by WebSpace')
    service = adb('shell', 'dumpsys', 'activity', 'services', APP)
    (OUT / 'services-active.txt').write_text(service)
    if 'ScreenShareService' not in service or 'isForeground=true' not in service:
        raise RuntimeError('ScreenShareService is not running in the foreground')
    evidence('05-live-screen')
    time.sleep(8)
    adb('shell', 'cmd', 'statusbar', 'expand-notifications')
    wait_node(['Sharing your screen'])
    evidence('06-sharing-notification')
    time.sleep(5)
    tap_label('Stop sharing')
    adb('shell', 'cmd', 'statusbar', 'collapse')
    wait_event('ended')
    projection = adb('shell', 'dumpsys', 'media_projection')
    (OUT / 'projection-stopped.txt').write_text(projection)
    if APP in projection:
        raise RuntimeError('WebSpace still owns MediaProjection after Stop sharing')
    wait_node(['Screen sharing stopped'])
    evidence('07-stopped')
    time.sleep(4)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ('result.json', 'screen-sharing.webm', 'screen-sharing.mp4'):
        (OUT / name).unlink(missing_ok=True)
    if not APK.exists():
        raise FileNotFoundError(APK)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', PORT), DemoServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    recording = False
    logcat = None
    raw = OUT / 'screen-sharing.webm'
    try:
        adb('wait-for-device')
        if adb('shell', 'getprop', 'ro.kernel.qemu') != '1':
            raise RuntimeError('This walkthrough clears app data; use a disposable emulator')
        adb('install', '-r', str(APK), timeout=90)
        adb('shell', 'pm', 'clear', APP)
        adb('shell', 'pm', 'grant', APP, 'android.permission.POST_NOTIFICATIONS')
        adb('shell', 'svc', 'power', 'stayon', 'true')
        adb('shell', 'settings', 'put', 'system', 'screen_off_timeout', '2147483647')
        adb('shell', 'settings', 'put', 'system', 'show_touches', '1')
        adb('shell', 'input', 'keyevent', '82')
        adb('reverse', f'tcp:{PORT}', f'tcp:{PORT}')
        # Finish the cold app launch before the encoder competes for CPU.
        adb('shell', 'am', 'start', '-W', '-n', f'{APP}/.MainActivity')
        wait_node(['Add', 'Add Site'], timeout=120)
        adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        time.sleep(3)
        adb('logcat', '-c')
        with (OUT / 'logcat.txt').open('wb') as log:
            logcat = subprocess.Popen([*ADB, 'logcat', '-v', 'threadtime'], stdout=log)
        (OUT / 'build.json').write_text(json.dumps({
            'commit': run('git', 'rev-parse', 'HEAD').decode().strip(),
            'apk_sha256': hashlib.sha256(APK.read_bytes()).hexdigest(),
            'variant': 'fdroidRelease',
            'android_api': adb('shell', 'getprop', 'ro.build.version.sdk'),
            'recorder': 'adb emu screenrecord (host emulator, not MediaProjection)',
        }, indent=2) + '\n')
        console('screenrecord', 'start', '--time-limit', '180', str(raw))
        recording = True
        began = time.monotonic()
        walkthrough()
        elapsed = time.monotonic() - began
        console('screenrecord', 'stop')
        recording = False
        run('ffmpeg', '-y', '-i', str(raw), '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
            '-movflags', '+faststart', str(OUT / 'screen-sharing.mp4'), timeout=120)
        duration = float(run('ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                             '-of', 'default=noprint_wrappers=1:nokey=1', str(raw)))
        if duration < 20 or duration + 10 < elapsed or elapsed >= 175:
            raise RuntimeError(f'Recording may be incomplete: video={duration:.1f}s, tour={elapsed:.1f}s')
        (OUT / 'result.json').write_text(json.dumps({
            'success': True, 'video_seconds': duration, 'walkthrough_seconds': elapsed,
        }, indent=2) + '\n')
        print(f'PASS: {OUT / "screen-sharing.mp4"}', flush=True)
    finally:
        if recording:
            console('screenrecord', 'stop')
        if logcat is not None:
            logcat.terminate()
            logcat.wait(timeout=10)
        server.shutdown()
        server.server_close()
        adb('reverse', '--remove', f'tcp:{PORT}')


if __name__ == '__main__':
    main()
