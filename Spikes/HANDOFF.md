# Backend / Playback spike 인수인계

2026-09-28 기준. 목적: 실제 YouTube 응답과 iOS 27 runtime으로 데이터·인증·재생 경로를 결정할 evidence 확보. 제품 기능 구현이 아니다.
표기: **[확인]** 이 환경에서 실제 응답/실기기로 관찰 · **[가설]** 추론 또는 외부 자료 · **[미검증]** 시도하지 않음.

## 1. 저장소 상태

- `main` = `9e1965a` (mock UI checkpoint). `spike/innertube-playback` = main + (1) Xcode Personal Team signing commit + (2) 이 문서를 포함한 spike checkpoint commit. `outputs/`, `references/`는 기존 정책대로 미추적.
- 앱(`MusicPrototype/`) 소스는 이번 spike에서 수정하지 않았다. 앱 build 정상.
- `MusicPrototype.xcodeproj` / scheme diff는 사용자가 Xcode에서 Personal Team(`DEVELOPMENT_TEAM`, automatic)을 지정하며 Xcode가 파일을 재서식한 결과다. spike 코드가 아니다.
- spike 코드: `Spikes/InnerTubeProbe`(SwiftPM, macOS CLI + library), `Spikes/WebPlayerSpike`(별도 iOS app, bundle `dev.ema.WebPlayerSpike`, MusicPrototype와 target·bundle·profile 분리).

## 2. 도구

`Spikes/InnerTubeProbe` — `swift build` 후 `.build/debug/itprobe`.

| 명령 | 용도 |
|---|---|
| `raw <name> <endpoint> <client> '<json>' [--auth]` | 요청 1회, redacted dump를 `$PROBE_OUT`에 저장 |
| `matrix <videoId>… [--clients A,B] [--auth]` | client별 `/player` 요약, 직접 URL range 도달성, HLS 확인 |
| `hls <videoId>… --auth [--play]` | WEB_SAFARI HLS master→media→segment, `--play`는 macOS AVPlayer(muted) |
| `authcheck` | 같은 data 요청을 anonymous vs auth로 비교 |
| `oauth-device` | 사용자 소유 OAuth client로 device flow |
| `normalize <release|artist|search|suggest|queue> <dump>` | 저장된 dump → 도메인 형태 |

- 인증 파일은 `ITPROBE_AUTH`로 지정, **저장소 내부 경로는 거부**. 브라우저 "모두 복사" 헤더 JSON(`requestHeaders.headers[]`)에서 Cookie / X-Goog-AuthUser / session Visitor-Id만 사용하고, `Authorization`은 재사용하지 않고 요청마다 SAPISIDHASH(+1P/3P)를 새로 계산한다.
- 값은 출력·저장하지 않는다. Redactor가 signed media URL, visitor/account 식별자를 dump에서 제거한다. dump는 scratchpad에만 두었다.
- Client identity 값(`Transport.swift`)은 yt-dlp master(2026-09) 참고. IOS_MUSIC version은 **추측값**.

## 3. 인증 결과 [확인]

| 방식 | 데이터 | `/player` |
|---|---|---|
| anonymous (KR) | 앨범/싱글/아티스트/검색/제안/`/next` 현재곡만. Home "Premium 회원에게만 제공", 재생목록·보관함·기록·좋아요 비어 있음, 검색·아티스트에서 **노래 결과 제외**, 라디오 1곡 | WEB_REMIX UNPLAYABLE(Music Premium 전용), WEB/SAFARI/IOS는 SABR-only, IOS_MUSIC LOGIN_REQUIRED |
| OAuth (사용자 GCP client, device flow, scope youtube) | 토큰 발급 성공, 그러나 **모든 요청 HTTP 400 INVALID_ARGUMENT** | 5 client 전부 400 |
| browser-session cookie (Premium) | 전부 정상. `logged_in=1`, `has_unlimited_entitlement=True`. Home, 보관함 26, 기록 200, 좋아요 100, 편집 재생목록 78, 아티스트 인기곡 포함, 검색 노래 필터, 라디오 50+continuation | 아래 5절 |

결론: 계정 데이터 인증은 **cookie session**. OAuth는 이 환경에서 부적합(헤더 변형 우회 시도 안 함).

## 4. 데이터 endpoint와 domain 수정점

사용 가능 [확인, cookie]: `browse`(FEmusic_home, FEmusic_liked_playlists, FEmusic_history, VLLM, VL…, MPREb_…, UC…), `search`, `music/get_search_suggestions`, `next`(+continuation). Swift 경로 `InnerTubeTransport → JSON → Normalize` 동작 확인(release/artist/search/suggest/queue).

현재 domain에서 바꿀 것:
- `ArtworkTheme` → artwork URL.
- 목록 맥락에서는 Release kind를 모를 수 있음(아티스트 "앨범" carousel은 연도만) → kind optional 또는 summary type.
- Release kind·연도는 **지역화 텍스트**("앨범 • 2017년")로만 옴 → locale table 필요.
- 앨범 페이지 하단 shelf는 서버 제목("맞춤 발표곡")이고 **다른 아티스트 포함** → "<아티스트>의 다른 음악"으로 가정 금지.
- 아티스트 header: 셔플(`RDAO…`), 믹스(`RDEM…`) watchPlaylist id. description은 anonymous에서 없음.
- track별 unplayable 상태(`unplayableText`) 보존.
- Search 결과는 `musicShelfRenderer`가 아니라 결과별 `itemSectionRenderer`로 올 수 있음.
- Queue entry = primary + optional counterpart + segmentMap(아래).

## 5. `/next` Song ↔ Video [확인, cookie]

```
playlistPanelVideoWrapperRenderer
  primaryRenderer.playlistPanelVideoRenderer        (videoId, musicVideoType ATV|OMV)
  counterpart[]
    counterpartRenderer.playlistPanelVideoRenderer  (다른 videoId, 반대 type)
    segmentMap.segment[] { primaryVideoStartTimeMilliseconds,
                           counterpartVideoStartTimeMilliseconds,
                           durationMilliseconds }
```
- 예: 밤편지 ATV `NnRjwEhFU70` ↔ OMV `BzYnNdJhZQw`, song 0 ↔ video 24013 ms, 250487 ms. 보라빛 밤 `wh7j1uEpNsQ` ↔ `H8YW1tlsmE8`, 0 ↔ 11521 ms. OMV가 primary면 대칭.
- counterpart 없는 항목은 plain `playlistPanelVideoRenderer` (라디오 50개 중 14개만 쌍).
- 별도 toggle 객체 없음. 전환 UI는 counterpart 존재로 결정.

## 6. `/player` 결과와 native blocker [확인]

| Client | Auth | 결과 |
|---|---|---|
| WEB_REMIX | cookie | OK. audio 6개 전부 `signatureCipher`(itag 141 AAC 256k, 774 Opus 256k 포함), 내부 URL에 `n` 존재. HLS 없음 |
| WEB_SAFARI | cookie | SABR(URL 없음) + **HLS manifest 제공**(muxed avc1+mp4a만, audio-only 없음). master/media playlist 200, **segment 전부 403**. segment URL에 `n` 있음, `pot` 없음 |
| WEB | cookie | SABR (24 중 23 URL 없음) |
| IOS / IOS_MUSIC | anonymous(cookie 비적용) | SABR / LOGIN_REQUIRED |
| 전부 | OAuth | 400 |

- macOS AVPlayer로 인증 HLS 재생: playlist(253s) 파싱 후 `NSURLErrorDomain -1102`(segment 403), 위치 0.
- Native blocker: signature + n transform(player JS 실행) 필요 [확인]. HLS 403 원인이 n 미변환인지 POT 부재인지는 **분리 못함** [가설]. 둘 다 합의된 "우회 구현 중단" 범위라 구현하지 않음.
- 참고 [가설]: IOS 응답의 `mediaCommonConfig`(UMP/platypus/serverDrivenAbr)와 `hlsProxyConfig` → 공식 iOS 앱은 SABR→local HLS proxy→AVPlayer로 보임.

## 7. WebPlayerSpike (실제 iPhone 15 Pro Max, iOS 27)

구성: WKWebView(persistent store, inline playback, background audio mode, AVAudioSession `.playback`), 관찰용 probe script(document start), native lifecycle/volume/route observer, 로그는 앱 `Documents/probe.log`(devicectl로 회수). 페이지 동작을 바꾸는 코드는 없다(래퍼는 원 함수를 그대로 호출하고 호출 맥락만 기록).

- 로그인: WKWebView 안 Google 로그인·2단계 인증 가능 [확인]. 로그인 후 youtube.com 이동이 universal link로 **YouTube 앱에 넘어감** → cross-site GET 이동을 `webView.load`로 재발행(public API)해 해결 [확인].
- iPhone에서는 **mobile web YTM**만 동작. desktop mode는 "사용 중인 브라우저에 최적화되지 않음". `MediaSource` 없음, `ManagedMediaSource` 있음(AAC/Opus 지원) [확인]. desktop 차단 원인이 MSE 부재라는 것은 [가설].
- Simulator는 media decode 실패(시간 0 고정) → 판단 근거로 쓰지 않음.

실기기 결과 [확인]:
- **지속 재생**: 밤편지 7.3 → 100.3 s, wall 93 s = media 93 s, stall 없음, 같은 video element, `blob:`(MMS).
- **Song ↔ Video 4회**: 170.2→194.2, 210.6→186.6, 200.7→224.7, 230.4→206.4 (±24.00 s, segmentMap과 0.1 s 이내). 같은 player·같은 `<video>` element, 페이지 이동 없음. 매번 새 source(emptied→loadedmetadata→seeked→playing), 재생 공백 **1067–1185 ms (약 1.1 s)** — gapless 아님. 청감 공백은 사용자 보고 없음.
- **Background/lock 실패 원인**: app background 후 +142 ms `visibilitychange(hidden)` → 그 handler 안에서 페이지가 `video.removeAttribute('src')`(+143 ms), `video.load()`(+152 ms) 호출 → detach. Foreground 복귀 시 `visibilitychange(visible)` handler에서 새 `blob:` src 설정(+10 ms) → sourceopen → addSourceBuffer → 저장 위치로 seek. **원인은 YouTube Music 페이지 로직**. audio session interruption 없음.
- **대조 테스트(로컬 tone, YouTube 없음)**: A plain file, B MMS 전체 선append, C MMS incremental streaming(hidden 상태에서도 append 계속) — **셋 다 잠금 20 s+ 연속 재생**, 잠금화면 재생/일시정지 정상. 즉 WKWebView background audio와 MMS background streaming 자체는 문제 아님.
- **Now Playing**: 잠금화면에 제목·10초 앞/뒤·재생 버튼 표시되지만 재생 명령은 페이지 detach로 실패("재생 중이 아님").
- **Control Center**: foreground에서만 동작.
- **시스템 볼륨**: 하드웨어 버튼·제어센터 모두 실제 음량 변경. 단 앱의 `AVAudioSession.outputVolume` KVO는 초기값 외 이벤트 0 → 동기화 slider는 `MPVolumeView` 후보 [미검증].
- AirPods/Bluetooth route, interruption(전화 등) [미검증].

## 8. Unresolved blocker와 다음 결정

현재 사실: Song↔Video를 포함한 "완전한 음악 앱" 재생 경로는 모두 우회가 필요하다.
- Native: signature/n (+ 경우에 따라 POT) — 곡·영상 양쪽 stream.
- Web-backed: 전환은 실제 client로 동작하지만 background 재생은 페이지의 hidden handler가 막음 → 해결하려면 visibility 위장/handler 무력화 = 우회.

사용자 결정 필요(범위·약관 판단):
1. 우회 없이: web-backed foreground 전용, 또는 앱은 browse/library UI + 재생은 공식 YTM 앱으로 hand-off.
2. 우회 경로 채택 여부와 어느 것(native sig/n/POT vs web visibility).
3. 결정 전 가능한 작업: cookie session 기반 InnerTube data layer를 앱 domain에 연결(4절 수정점), Queue model에 counterpart/segmentMap 반영.
4. 결정: native playback 연구를 계속하며 data integration은 병행. Web foreground-only / official-app handoff는 제품 경로로 채택하지 않음.

그 외 미검증: authenticated IOS 계열(cookie 비적용·OAuth 거부로 불가), `visionos`/ANDROID_MUSIC 등 추가 client(범위 밖으로 보류), 실제 기기 AVPlayer(재생 가능한 URL 없음).

## 9. 민감정보 / 정리

- `~/.config/itprobe/`의 `browser-headers.itprobe-auth`(전체 로그인 세션), `oauth.itprobe-auth`(refresh token 포함), `oauth-client.env`, `oauth-client.env.save`(client secret)는 저장소 밖 파일이며 실험 후 삭제 권장. GCP OAuth client와 Google 계정의 앱 접근 권한도 해제 가능.
- iPhone의 WebPlayerSpike는 free profile 3개 slot 중 1개를 사용하며 자체 WKWebView 로그인 세션을 갖는다.
- Local tone은 재생성 가능: `ffmpeg -f lavfi -i "sine=frequency=440:beep_factor=4:duration=240:sample_rate=44100" -af volume=0.3 -c:a aac -b:a 96k tone.m4a` 후 `ffmpeg -i tone.m4a -c copy -movflags frag_keyframe+empty_moov+default_base_moof -frag_duration 2000000 tone_frag.mp4`.
