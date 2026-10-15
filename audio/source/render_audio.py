"""Original deterministic phase-six score and foley synthesis; no sampled third-party media."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import wave
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

ROOT = Path(__file__).resolve().parents[1]
RATE = 48000
_ffmpeg_path = os.environ.get('PHASE6_FFMPEG') or shutil.which('ffmpeg')
if not _ffmpeg_path or not Path(_ffmpeg_path).is_file():
    raise RuntimeError('Set PHASE6_FFMPEG to an existing FFmpeg executable or add FFmpeg to PATH.')
FFMPEG = Path(_ffmpeg_path)
RNG = np.random.default_rng(20261005)
SCORE = []


def hz(midi):
    return 440 * 2 ** ((midi - 69) / 12)


def tone(midi, seconds, instrument, velocity=1.0):
    t = np.arange(max(2, round(seconds * RATE))) / RATE
    f = hz(midi)
    if instrument == 'lute':
        signal = sum(np.sin(2*np.pi*f*k*t + .012*k) * (1/k**1.8)
                     * np.exp(-t*(2.7 + .6*k)) for k in range(1, 7))
        envelope = np.minimum(1, t/.004) * np.minimum(1, (seconds-t)/.035)
    elif instrument == 'flute':
        phase = 2*np.pi*f*t + .035*np.sin(2*np.pi*4.3*t)
        signal = np.sin(phase) + .13*np.sin(2*phase) + .035*np.sin(3*phase)
        envelope = np.minimum(1, t/.045) * np.minimum(1, (seconds-t)/.12)
    elif instrument == 'strings':
        signal = sum(np.sin(2*np.pi*f*k*t + .018*k*np.sin(2*np.pi*3*t)) / k**1.65
                     for k in range(1, 7))
        envelope = np.minimum(1, t/.12) * np.minimum(1, (seconds-t)/.25)
    elif instrument == 'brass':
        signal = sum(np.sin(2*np.pi*f*k*t)/k**1.2 for k in range(1, 6))
        envelope = np.minimum(1, t/.03) * np.minimum(1, (seconds-t)/.09)
        signal *= .75 + .25*np.minimum(1, t/.06)
    elif instrument == 'bell':
        signal = sum(np.sin(2*np.pi*f*k*t) * np.exp(-t*(2+k)) / k**1.3
                     for k in [1, 2.01, 2.98, 4.07])
        envelope = np.minimum(1, t/.003) * np.minimum(1, (seconds-t)/.03)
    else:
        signal = np.sin(2*np.pi*f*t) + .24*np.sin(4*np.pi*f*t)
        envelope = np.minimum(1, t/.018) * np.minimum(1, (seconds-t)/.06)
    return signal * np.clip(envelope, 0, 1) * velocity


def noise(seconds, cutoff=3200):
    n = round(seconds*RATE)
    raw = RNG.normal(0, 1, n)
    return sosfilt(butter(2, cutoff, fs=RATE, output='sos'), raw)


def drum(seconds=.22, pitch=90, strength=1):
    t = np.arange(round(seconds*RATE))/RATE
    phase = 2*np.pi*(pitch*t + 16*(1-np.exp(-t*35))/35)
    return (np.sin(phase)*np.exp(-t*23) + noise(seconds, 1300)*.22*np.exp(-t*40)) * strength


def add_loop(buf, signal, start, gain, pan=0):
    start = round(start*RATE) % len(buf)
    signal = signal * gain
    stereo = np.column_stack((signal*np.sqrt((1-pan)/2), signal*np.sqrt((1+pan)/2)))
    first = min(len(stereo), len(buf)-start)
    buf[start:start+first] += stereo[:first]
    remainder = stereo[first:]
    while len(remainder):
        count = min(len(remainder), len(buf))
        buf[:count] += remainder[:count]
        remainder = remainder[count:]


def note(buf, bpm, beat, midi, beats, instrument, gain, pan=0):
    seconds = beats*60/bpm
    add_loop(buf, tone(midi, seconds, instrument), beat*60/bpm, gain, pan)
    SCORE.append(dict(bpm=bpm, beat=beat, midi=midi, beats=beats,
                      instrument=instrument, gain=gain, pan=pan))


def finish_music(buf):
    # Circular echo/reverb includes the previous pass's tail, so no silent seam is inserted.
    dry = buf.copy()
    for delay, gain in [(.137, .10), (.239, .085), (.401, .06), (.677, .04)]:
        buf += np.roll(dry[:, ::-1], round(delay*RATE), axis=0)*gain
    buf = np.tanh(buf*.95)
    buf *= .48 / max(.01, np.max(np.abs(buf)))
    return buf.astype(np.float32)


def exploration():
    bpm, bars = 84, 24
    buf = np.zeros((round(bars*4*60/bpm*RATE), 2))
    chords = [(50, 53, 57), (48, 52, 55), (43, 47, 50), (50, 53, 57),
              (45, 48, 52), (43, 47, 50), (48, 52, 55), (50, 53, 57)]
    melody = [[62, 65, 69, 67], [64, 67, 72, 67], [67, 71, 69, 67], [65, 64, 62, 69],
              [69, 72, 71, 69], [67, 69, 71, 67], [64, 67, 65, 64], [65, 64, 62, 62]]
    for bar in range(bars):
        chord = chords[bar % 8]
        # 8 bars of quiet foundation, 8 of dialogue, 8 of melodic variation and return.
        density = [0.60, 1.0, .83][bar//8]
        note(buf, bpm, bar*4, chord[0]-12, 3.95, 'bass', .14)
        for index, midi in enumerate(chord):
            note(buf, bpm, bar*4+.08*index, midi, 4.25, 'strings', .047*density, -.38+.38*index)
        for step in range(8):
            midi = chord[[0,1,2,1,0,2,1,2][step]]+12
            note(buf, bpm, bar*4+step*.5, midi, 1.0, 'lute', .12*density, -.3)
        if bar >= 8:
            for step, midi in enumerate(melody[bar % 8]):
                length = .76 if step < 3 else 1.18
                note(buf, bpm, bar*4+step+.1, midi+(12 if bar in [18,19] else 0), length, 'flute', .09*density, .35)
        if bar % 4 == 0:
            note(buf, bpm, bar*4+.03, chord[2]+24, 1.4, 'bell', .038, .5)
        for beat in [0, 2.5]:
            add_loop(buf, drum(.2, 100), (bar*4+beat)*60/bpm, .05*density, -.1)
    return finish_music(buf)


def combat():
    bpm, bars = 112, 32
    buf = np.zeros((round(bars*4*60/bpm*RATE), 2))
    chords = [(38, 41, 45), (34, 38, 41), (36, 40, 43), (33, 37, 40)]
    themes = [[62, 62, 65, 67, 69, 67, 65, 62], [65, 65, 69, 70, 69, 65, 62, 65],
              [67, 67, 64, 67, 72, 70, 67, 64], [69, 67, 65, 64, 61, 64, 69, 61]]
    for bar in range(bars):
        chord = chords[(bar//2) % 4]
        phase = bar//8
        density = [0.72, 1.0, .80, .96][phase]
        for step in range(8):
            root = chord[0]+(12 if step in [3,7] else 0)
            note(buf, bpm, bar*4+step*.5, root, .43, 'strings', .11*density, -.26)
            note(buf, bpm, bar*4+step*.5, chord[[0,2,1,2][step%4]]+24, .6, 'lute', .047*density, .36)
        for index,midi in enumerate(chord):
            note(buf, bpm, bar*4, midi+12, 2.7, 'strings', .045, -.25+.25*index)
        if phase in [1,3] or (phase == 2 and bar % 2 == 0):
            notes = themes[(bar//2) % 4]
            for step,midi in enumerate(notes):
                note(buf, bpm, bar*4+step*.5, midi, .40 if step<7 else .7, 'brass', .040*density, .14)
        else:
            for step in [0,2]:
                note(buf, bpm, bar*4+step, chord[2]+24, 1.35, 'flute', .04, .25)
        for beat in [0, 1.5, 2, 3.5]:
            add_loop(buf, drum(.28, 65 if beat in [0,2] else 125), (bar*4+beat)*60/bpm, .13*density)
        for step in range(8):
            click = noise(.085, 5000) * np.exp(-np.arange(round(.085*RATE))/RATE*70)
            add_loop(buf, click, (bar*4+step*.5)*60/bpm, .026*density, .35)
    return finish_music(buf)


def foley(name):
    lengths = {'ui_confirm':.095,'ui_invalid':.11,'card_play':.21,'strike_hit':.19,
               'block_gain':.20,'block_hit':.15,'weapon_break':.30,'heal_gain':.36,
               'end_turn':.175,'victory':1.15,'defeat':1.32}
    seconds=lengths[name]
    t=np.arange(round(seconds*RATE))/RATE
    signal=np.zeros(len(t))
    if name=='ui_confirm':
        signal=drum(seconds,410)*.55+tone(86,seconds,'bell',.15)
    elif name=='ui_invalid':
        signal=drum(seconds,125)*.5+noise(seconds,1200)*np.exp(-t*25)*.3
    elif name=='card_play':
        signal=noise(seconds,4500)*np.exp(-t*15)*.3+drum(seconds,210)*.45
    elif name=='strike_hit':
        signal=drum(seconds,95)*.65+noise(seconds,6000)*np.exp(-t*34)*.45+tone(62,seconds,'bell',.15)
    elif name=='block_gain':
        signal=tone(62,seconds,'bell',.5)+tone(69,seconds,'bell',.26)+drum(seconds,185)*.2
    elif name=='block_hit':
        signal=drum(seconds,180)*.7+tone(74,seconds,'bell',.35)+noise(seconds,5000)*np.exp(-t*40)*.3
    elif name=='weapon_break':
        signal=noise(seconds,6900)*np.exp(-t*25)*.45+tone(77,seconds,'bell',.3)+tone(83,seconds,'bell',.18)
        for delay,midi in [(.04,90),(.082,86),(.135,81)]:
            n=round(delay*RATE); signal[n:]+=tone(midi,seconds-delay,'bell',.17)[:len(signal)-n]
    elif name=='heal_gain':
        signal=tone(74,seconds,'bell',.45)+tone(81,seconds,'flute',.14)
    elif name=='end_turn':
        signal=drum(seconds,245)*.45+tone(79,seconds,'bell',.23)
    else:
        pitches=[62,65,69,74] if name=='victory' else [50,48,45,38]
        for index,midi in enumerate(pitches):
            start=round(index*.15*RATE)
            signal[start:]+=tone(midi,seconds-index*.15,'brass' if name=='victory' else 'strings',.25)[:len(signal)-start]
        signal += drum(seconds,70)*.23
    signal*=np.minimum(1,t/.002)*np.minimum(1,(seconds-t)/.015)
    peak=.35 if name in ['ui_confirm','ui_invalid'] else .70
    signal=signal/(max(.001,np.max(np.abs(signal))))*peak
    return signal.astype(np.float32)


def pcm(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    wavfile.write(path,RATE,(np.clip(data,-1,1)*32767).astype(np.int16))


def main():
    source=ROOT/'source'
    manifest={'original':True,'seed':20261005,'sample_rate':RATE,'assets':[]}
    for name in ['ui_confirm','ui_invalid','card_play','strike_hit','block_gain','block_hit',
                 'weapon_break','heal_gain','end_turn','victory','defeat']:
        data=foley(name)
        wavfile.write(source/(name+'-source.wav'),RATE,data)
        pcm(ROOT/'sfx'/(name+'.wav'),data)
        manifest['assets'].append({'id':name,'seconds':len(data)/RATE,'peak':float(np.max(np.abs(data))),
                                   'rms':float(np.sqrt(np.mean(data**2)))})
    for name,builder,bpm,bars in [('exploration',exploration,84,24),('combat',combat,112,32)]:
        data=builder()
        wavfile.write(source/(name+'-source.wav'),RATE,data)
        pcm(source/(name+'-pcm.wav'),data)
        out=ROOT/'music'/(name+'.ogg');out.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run([str(FFMPEG),'-y','-loglevel','error','-i',str(source/(name+'-pcm.wav')),
                        '-c:a','libvorbis','-q:a','5',str(out)],check=True)
        pcm(ROOT/'preview'/(name+'-preview.wav'),data[RATE*24:RATE*36])
        manifest['assets'].append({'id':name,'bpm':bpm,'bars':bars,'seconds':len(data)/RATE,
                                   'peak':float(np.max(np.abs(data))),
                                   'rms':float(np.sqrt(np.mean(data**2))),
                                   'seam_step':float(np.max(np.abs(data[-1]-data[0])))})
    (source/'score.json').write_text(json.dumps(SCORE,indent=2),encoding='utf-8')
    (ROOT/'asset_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps(manifest,indent=2))


if __name__=='__main__':
    main()
