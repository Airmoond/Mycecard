# 音频

游戏使用两首循环音乐和11种短音效。运行时播放由[GameAudioManager](./audio_manager.gd)负责，声音设置位于[AudioSettings](../ui/audio_settings.tscn)，战斗反馈由表现层消费真实规则事件后触发。

## 文件

| 路径 | 用途 |
| --- | --- |
| music/ | 游戏使用的立体声OGG音乐 |
| sfx/ | 游戏使用的单声道WAV短音效 |
| [asset_manifest.json](./asset_manifest.json) | 素材标识、时长、采样率和编配信息 |
| [source/render_audio.py](./source/render_audio.py) | 确定性合成编曲与音效制作 |
| [source/score.json](./source/score.json) | 音符和声部编配记录 |
| [source/check_audio.py](./source/check_audio.py) | 解码、峰值、非静音、素材差异与循环接缝检查 |

素材由振荡器、谐波、包络、滤波噪声和混响合成，随机种子为20261005，未使用第三方音轨、采样或SoundFont。音色名称描述合成方向。

游戏短声为48 kHz、16-bit PCM单声道WAV；音乐为48 kHz立体声OGG Vorbis，编码质量5。制作源保留48 kHz、32-bit float WAV，音乐另有16-bit PCM试听源。

| 音乐 | 编配 | 循环长度 |
| --- | --- | ---: |
| exploration | 84 BPM、4/4、24小节；探索页面使用 | 68.5714375秒 |
| combat | 112 BPM、4/4、32小节；战斗页面使用 | 68.5714375秒 |

短声标识包括 ui_confirm、ui_invalid、card_play、strike_hit、block_gain、block_hit、weapon_break、heal_gain、end_turn、victory 和 defeat。

## 播放接口

GameAudioManager 位于页面容器之外，跨页保留音量、静音和音乐进度。默认音乐音量为0.65，音效音量为0.80；设置仅在当前进程保留。

- set_music_state() 接受 exploration、combat 或 silence；同状态请求不重播，切换使用0.8秒交叉淡化。
- play_sfx() 接受素材标识、可选结果标识与优先级；结果标识用于去重不同来源的重复反馈。
- 短声池最多8条，其中UI最多2条；高优先级声音可以替换低优先级播放。
- shutdown() 停止新播放并清理播放源；应用通过 wait_for_shutdown() 等待已登记播放实例释放，默认5秒超时。
- 音乐与音效各有独立音量、静音，总静音覆盖两者。重要命中或胜败暂时压低音乐，Master使用-1 dB硬限制器保留输出余量。

声音和动画不参与规则结算。满血治疗不播放治疗声；全额格挡播放格挡命中声，不播放生命受击声；未执行的后续效果不发声。

## 可选制作与检查

运行游戏不需要Python音频依赖。修改或重制素材时，在项目根目录安装[可选依赖](../tools/requirements-audio.txt)，并让FFmpeg位于PATH，或通过 PHASE6_FFMPEG 指定可执行程序。

~~~powershell
python -m pip install -r tools/requirements-audio.txt
python tools/project.py doctor --optional audio
python audio/source/render_audio.py
python audio/source/check_audio.py
~~~

制作脚本会重建制作源、游戏素材、编配与素材清单；检查脚本会更新 source/audio-validation.json 和试听片段。修改前应保存需要保留的素材版本。

完整循环试听文件可通过以下命令生成；大体积三连循环PCM保存于项目忽略的 .godot/phase6-audio-pass：

~~~powershell
python audio/source/check_audio.py --full-loop-preview
powershell -File audio/source/playback_audio.ps1 -FullLoops
~~~

Windows试听脚本通过 SoundPlayer 播放文件并记录完成时间。未带 -FullLoops 时播放短声与轻量试听片段。

运行时音频检查使用项目的统一测试入口：

~~~powershell
python tools/project.py test --match '^(phase6_audio_feedback|app_shutdown)_test[.]gd$'
~~~

循环长度、混音峰值和播放生命周期可自动检查；旋律、音色和默认响度仍需在实际播放设备上试听。
