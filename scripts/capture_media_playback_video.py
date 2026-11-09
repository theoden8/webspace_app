#!/usr/bin/env python3
"""Record user-started website audio and its real background media controls."""
import io
import json
import math
from pathlib import Path
import re
import signal
import struct
import subprocess
import threading
import time
import wave

import capture_screen_share_video as capture


capture.OUT = capture.ROOT / 'build/media-playback-video'
capture.PAGE = capture.ROOT / 'tool/media_playback_demo/index.html'
OUT = capture.OUT


def melody():
    notes = [261.63, 329.63, 392, 523.25, 392, 329.63, 293.66, 349.23]
    data = bytearray()
    rate = 22050
    for i in range(180 * rate):
        t = i / rate
        phase = t % .5
        envelope = min(1, phase / .02, (.5 - phase) / .04)
        value = .18 * envelope * math.sin(2 * math.pi * notes[int(t * 2) % len(notes)] * t)
        data.extend(struct.pack('<h', int(value * 32767)))
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(data)
    return buffer.getvalue()


class Server(capture.DemoServer):
    audio = melody()

    def do_GET(self):
        if self.path != '/demo.wav':
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'audio/wav')
        self.send_header('Content-Length', str(len(self.audio)))
        self.end_headers()
        self.wfile.write(self.audio)


def scroll_to(label):
    for _ in range(12):
        matches = capture.labelled(capture.ui(), [label])
        if matches:
            return matches[0]
        width, height = map(int, re.findall(r'\d+', capture.adb('shell', 'wm', 'size'))[-2:])
        capture.adb('shell', 'input', 'swipe', str(width // 2), str(height * 4 // 5),
                    str(width // 2), str(height // 3), '400')
    raise RuntimeError(f'Cannot find {label}')


def enable_background_audio():
    capture.tap_label('Show menu', 'Menu')
    capture.tap_label('Settings')
    permission_row = scroll_to('Permissions')
    left, top, right, bottom = map(int, re.findall(r'\d+', permission_row.get('bounds', '')))
    capture.adb('shell', 'input', 'tap', str(left + (right - left) // 4),
                str((top + bottom) // 2))
    label = scroll_to('Background audio')
    tree = capture.ui()
    switches = [n for n in tree.iter('node') if n.get('class') == 'android.widget.Switch']
    def bounds(node):
        return list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
    def mid(node):
        b = bounds(node)
        return (b[1] + b[3]) // 2
    target = min(switches, key=lambda n: abs(mid(n) - mid(label)))
    if abs(mid(target) - mid(label)) > 150:
        raise RuntimeError('No Background audio switch beside its label')
    if target.get('checked') != 'true':
        left, top, right, bottom = bounds(target)
        capture.adb('shell', 'input', 'tap', str(right - (right - left) // 12),
                    str((top + bottom) // 2))
    switches = [n for n in capture.ui().iter('node') if n.get('class') == 'android.widget.Switch']
    if min(switches, key=lambda n: abs(mid(n) - mid(label))).get('checked') != 'true':
        raise RuntimeError('Background audio is not enabled')
    capture.evidence('01-background-audio-setting')
    capture.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    capture.tap(scroll_to('Save Settings'))
    capture.wait_node(['Play audio'])


def progress_after(moment, minimum):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        with capture.EVENT_LOCK:
            events = list(capture.EVENTS)
        for event in events:
            if (event['event'] == 'progress' and event['time'] > moment and
                    not event['paused'] and event['currentTime'] >= minimum):
                return event
        time.sleep(.25)
    raise RuntimeError('Audio did not advance while WebSpace was in the background')


def audio_diagnostics(name):
    for service in ['audio', 'media.audio_flinger', 'media.audio_policy']:
        (OUT / f'{name}-{service}.txt').write_text(capture.adb('shell', 'dumpsys', service))


def walkthrough():
    capture.adb('shell', 'am', 'start', '-W', '-n', f'{capture.APP}/.MainActivity')
    capture.wait_node(['Play audio'])
    time.sleep(1)
    capture.tap_label('Play audio')
    playing = capture.wait_event('playing')
    progress_after(playing['time'], 2)
    audio_diagnostics('playing')
    capture.evidence('02-audio-playing')
    services = capture.adb('shell', 'dumpsys', 'activity', 'services', capture.APP)
    (OUT / 'services-playing.txt').write_text(services)
    if 'MediaPlaybackService' not in services or 'isForeground=true' not in services:
        raise RuntimeError('The real foreground MediaPlaybackService is missing')
    sessions = capture.adb('shell', 'dumpsys', 'media_session')
    (OUT / 'sessions-playing.txt').write_text(sessions)
    if capture.APP not in sessions or not re.search(r'state=(?:PLAYING\()?3(?:\)|\b)', sessions):
        raise RuntimeError('Android does not report a playing WebSpace media session')
    with capture.EVENT_LOCK:
        baseline = next(e for e in reversed(capture.EVENTS) if e['event'] == 'progress')
    capture.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    left = time.time()
    progress_after(left, baseline['currentTime'] + 4)
    audio_diagnostics('background')
    capture.evidence('03-audio-continues-on-home')
    capture.adb('shell', 'cmd', 'statusbar', 'expand-notifications')
    capture.wait_node(['Demo melody', 'WebSpace audio demo', 'Audio playback demo'])
    capture.evidence('04-media-notification')
    time.sleep(2)
    capture.tap_label('Pause')
    capture.wait_event('paused')
    capture.evidence('05-notification-paused')
    sessions = capture.adb('shell', 'dumpsys', 'media_session')
    (OUT / 'sessions-paused.txt').write_text(sessions)
    if capture.APP not in sessions or not re.search(r'state=(?:PAUSED\()?2(?:\)|\b)', sessions):
        raise RuntimeError('Android does not report paused playback after notification Pause')
    capture.adb('shell', 'cmd', 'statusbar', 'collapse')
    capture.adb('shell', 'am', 'start', '-W', '-n', f'{capture.APP}/.MainActivity')
    capture.wait_node(['Audio paused'])
    capture.evidence('06-audio-paused')
    time.sleep(2)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    server = capture.http.server.ThreadingHTTPServer(('127.0.0.1', capture.PORT), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    recorder = None
    try:
        capture.prepare_emulator()
        capture.open_demo_site(title='Audio playback demo')
        enable_background_audio()
        capture.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        capture.adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--set', '15')
        recording_log = OUT / 'recorder.log'
        with recording_log.open('w') as log:
            recorder = subprocess.Popen(['scrcpy', '--no-window', '--no-playback', '--no-control',
                '--require-audio', '--audio-codec=aac', '--max-fps=30',
                '--video-bit-rate=4M', '--time-limit=180',
                f'--record={OUT / "media-playback.mkv"}'], stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while ('recording started' not in recording_log.read_text().lower() or
               not (OUT / 'media-playback.mkv').exists() or
               (OUT / 'media-playback.mkv').stat().st_size == 0):
            if recorder.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(recording_log.read_text())
            time.sleep(.2)
        began = time.monotonic()
        walkthrough()
        elapsed = time.monotonic() - began
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=20)
        recorder = None
        (OUT / 'audio-logcat.txt').write_text(capture.adb('logcat', '-d', '-t', '5000'))
        source_check = subprocess.run(['ffmpeg', '-i', str(OUT / 'media-playback.mkv'),
            '-af', 'volumedetect', '-vn', '-f', 'null', '-'], capture_output=True,
            text=True, check=True)
        (OUT / 'source-audio-volume.txt').write_text(source_check.stderr)
        source_peak = re.search(r'max_volume: (-?[\d.]+) dB', source_check.stderr)
        if not source_peak or float(source_peak[1]) < -65:
            raise RuntimeError('The original emulator recording contains no usable audio')
        capture.run('ffmpeg', '-y', '-i', str(OUT / 'media-playback.mkv'),
            '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p',
            '-af', 'aresample=async=1:first_pts=0,loudnorm=I=-18:TP=-2:LRA=11', '-c:a', 'aac',
            '-movflags', '+faststart', str(OUT / 'media-playback.mp4'), timeout=120)
        audio_check = subprocess.run(['ffmpeg', '-i', str(OUT / 'media-playback.mp4'),
            '-af', 'volumedetect', '-vn', '-f', 'null', '-'], capture_output=True,
            text=True, check=True)
        (OUT / 'audio-volume.txt').write_text(audio_check.stderr)
        peak = re.search(r'max_volume: (-?[\d.]+) dB', audio_check.stderr)
        if not peak or float(peak[1]) < -40:
            raise RuntimeError('The recorded emulator audio is silent')
        if elapsed >= 175:
            raise RuntimeError('The walkthrough exceeded the recorder limit')
        (OUT / 'result.json').write_text(json.dumps({'success': True,
            'walkthrough_seconds': elapsed, 'audio_peak_db': float(peak[1]),
            'design': 'legacy', 'app': capture.APP}, indent=2) + '\n')
        print('PASS: media-playback.mp4', flush=True)
    finally:
        if recorder is not None and recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=20)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
