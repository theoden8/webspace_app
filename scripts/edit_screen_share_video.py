from pathlib import Path
import json,re,subprocess,sys
import numpy as np
from PIL import Image
root=Path(sys.argv[1]).resolve()
source=root/('media-playback.mp4' if (root/'media-playback.mp4').exists() else 'screen-sharing.mp4')
playback=source.stem=='media-playback'
rate=12; width=270; height=585
proc=subprocess.Popen(['ffmpeg','-v','error','-i',str(source),'-vf',f'fps={rate},scale={width}:{height}','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
reference_rows=np.array([],dtype=int)
if (root/'05-live-screen.png').exists():
    reference=np.array(Image.open(root/'05-live-screen.png').convert('RGB').resize((width,height))).astype(np.int16)
    reference_rows=np.flatnonzero(((((reference.max(axis=2)-reference.min(axis=2))>50)&(reference.max(axis=2)>120)).sum(axis=1)>width*.45))
previous=None; previous_mask=None; activity=[]; index=0
while True:
    raw=proc.stdout.read(width*height*3)
    if not raw:break
    frame=np.frombuffer(raw,dtype=np.uint8).reshape(height,width,3).astype(np.int16)
    high=frame.max(axis=2); low=frame.min(axis=2)
    band=(((high-low)>50)&(high>120)).sum(axis=1)>width*.65
    rows=np.flatnonzero(band)
    mask=np.ones((height,width),dtype=bool);mask[:34]=False
    for y in np.union1d(rows,reference_rows):mask[max(0,y-3):min(height,y+4)]=False
    if previous is not None:
        changed=(np.abs(frame-previous).max(axis=2)>18)&mask&previous_mask
        if changed.sum()>width*height*.0005:activity.append(index/rate)
    previous=frame;previous_mask=mask;index+=1
proc.stdout.close()
if proc.wait()!=0:raise RuntimeError('Decoder failed')
duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(source)]))
# Keep the original speed of changing sequences and short context around each.
before,after,edge=(1.0,1.5,1.5) if playback else (.4,.5,1.0)
intervals=[[0,edge]]
for point in activity:
    start=max(0,point-before); end=min(duration,point+after)
    if start<=intervals[-1][1]+.25:intervals[-1][1]=max(end,intervals[-1][1])
    else:intervals.append([start,end])
if duration-edge<=intervals[-1][1]+.25:intervals[-1][1]=duration
else:intervals.append([duration-edge,duration])
result={'method':'Automatic frame activity detection; ignore status clock, compression noise and full-width animated gradient; preserve sequence order and playback speed.','source_seconds':duration,'output_seconds':sum(b-a for a,b in intervals),'retained_intervals':intervals,'significant_changes':len(activity)}
gain=0
if playback:
    volume=subprocess.run(['ffmpeg','-i',str(source),'-af','volumedetect','-vn','-f','null','-'],capture_output=True,text=True,check=True)
    peak=re.search(r'max_volume: (-?[\d.]+) dB',volume.stderr)
    if not peak:raise RuntimeError('Cannot measure the recorded audio')
    gain=-8-float(peak[1])
    result['recorded_audio_gain_db']=gain
(root/'idle-removal.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
parts=[];inputs=[]
for i,(a,b) in enumerate(intervals):
    parts += [f'[0:v]trim=start={a:.6f}:end={b:.6f},setpts=PTS-STARTPTS[v{i}]',f'[0:a]aresample=async=1:first_pts=0,apad,atrim=start={a:.6f}:end={b:.6f},asetpts=PTS-STARTPTS[a{i}]']
    inputs += [f'[v{i}][a{i}]']
parts.append(''.join(inputs)+f'concat=n={len(intervals)}:v=1:a=1[v][joined]')
parts.append(f'[joined]volume={gain}dB[a]')
(root/'idle-removal.ffmpeg').write_text(';\n'.join(parts))
subprocess.run(['ffmpeg','-y','-i',str(source),'-filter_complex_script',str(root/'idle-removal.ffmpeg'),'-map','[v]','-map','[a]','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-movflags','+faststart',str(root/f'{source.stem}-idle-removed.mp4')],check=True,stdout=subprocess.DEVNULL,stderr=(root/'idle-removal.log').open('w'))
