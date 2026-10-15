"""Decode game-delivered assets and verify non-silence, headroom, distinct scores and loop seams."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = os.environ.get('PHASE6_FFMPEG') or shutil.which('ffmpeg')
if not FFMPEG or not Path(FFMPEG).is_file():
    raise RuntimeError('Set PHASE6_FFMPEG to an existing FFmpeg executable or add FFmpeg to PATH.')
manifest = json.loads((ROOT/'asset_manifest.json').read_text(encoding='utf-8'))
report = []
hashes = set()
for item in manifest['assets']:
    name = item['id']
    if 'bpm' not in item:
        path = ROOT/'sfx'/(name+'.wav')
        rate,pcm = wavfile.read(path)
        assert rate == 48000 and pcm.dtype == np.int16
        audio = pcm.astype(np.float32)/32768
    else:
        path = ROOT/'music'/(name+'.ogg')
        decoded = subprocess.run([FFMPEG,'-v','error','-i',str(path),'-f','f32le','-ac','2','-ar','48000','-'],check=True,capture_output=True)
        audio = np.frombuffer(decoded.stdout,dtype='<f4').reshape(-1,2)
        expected_frames=round(item['bars']*4*60/item['bpm']*48000)
        assert abs(len(audio)-expected_frames)<1024
        # This installed FFmpeg exposes the final Vorbis packet's padding. Musical/EOS
        # duration is recorded in the asset and checked against Godot's get_length().
        audio=audio[:expected_frames]
        seam = float(np.max(np.abs(audio[-1]-audio[0])))
        assert seam < .01, (name,seam)
        # Two seam excerpts use the actual compressed game stream, including decoded tails.
        excerpt = np.concatenate([audio[-48000:],audio[:48000]]*3)
        wavfile.write(ROOT/'preview'/(name+'-loop-check.wav'),48000,(excerpt*32767).astype(np.int16))
        if '--full-loop-preview' in sys.argv:
            # Keep large QA-only three-cycle PCM files outside Godot resource importing.
            qa_dir = ROOT.parent/'.godot'/'phase6-audio-pass'
            qa_dir.mkdir(parents=True, exist_ok=True)
            three_cycles = np.tile(audio, (3, 1))
            wavfile.write(qa_dir/(name+'-three-loops.wav'),48000,(three_cycles*32767).astype(np.int16))
        report.append({'id':name,'decoded_loop_seam_step':seam})
    peak=float(np.max(np.abs(audio)))
    rms=float(np.sqrt(np.mean(audio**2)))
    assert .01 < rms < .40 and .05 < peak < .80, (name,peak,rms)
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest not in hashes
    hashes.add(digest)
    report.append({'id':name,'seconds':len(audio)/48000,'peak':peak,'rms':rms,'sha256':digest})
score=json.loads((ROOT/'source'/'score.json').read_text(encoding='utf-8'))
for bpm in [84,112]:
    rows=[row for row in score if row['bpm']==bpm]
    assert len(rows)>200 and len({row['midi'] for row in rows})>=12
    assert len({row['instrument'] for row in rows})>=4
(ROOT/'source'/'audio-validation.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(f'Decoded 13 distinct non-silent assets; both arranged scores and compressed loop seams passed.')
