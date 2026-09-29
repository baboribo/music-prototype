# Backend / Playback spike 인수인계

2026-09-28 기준. 목적: 실제 YouTube 응답과 iOS 27 runtime으로 데이터·인증·재생 경로를 결정할 evidence 확보. 제품 기능 구현이 아니다.
표기: **[확인]** 이 환경에서 실제 응답/실기기로 관찰 · **[가설]** 추론 또는 외부 자료 · **[미검증]** 시도하지 않음.

## 1. 저장소 상태

- `main` = `9e1965a` (mock UI checkpoint). `spike/innertube-playback` = main + (1) Xcode Personal Team signing commit + (2) 이 문서를 포함한 spike checkpoint commit. `outputs/`, `references/`는 기존 정책대로 미추적.
- 앱(`MusicPrototype/`) 소스는 spike checkpoint까지 수정하지 않았다. 그 다음 commit("A1–A5 InnerTube data integration checkpoint")이 8절 A축 A1–A5와 `AGENTS.md` 규칙 갱신을 담는다.
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

## 8. 결정과 진행 (2026-09-28 갱신)

결정: web foreground-only, 공식 YTM 앱 hand-off는 **채택하지 않음**. 두 축으로 진행, 서로 blocking하지 않음.

### A. 본 앱 data layer (단계: Home → Search → Release → Artist → Playlist → Library)
- 구조: `MusicPrototype/Domain/MusicCatalog.swift`(protocol + `MockMusicCatalog`, `HomeFeed`) ← `MusicPrototype/Service/InnerTube/`(JSON, `SessionCredential`, `InnerTubeClient`, `ItemParsing`, `LiveMusicCatalog`). View는 `\.musicCatalog`만 안다.
- Live 전환: 환경변수 `YTM_SESSION_FILE`(저장소 밖 경로만, 안이면 거부) 있을 때만. 없으면 fixture. Simulator: `SIMCTL_CHILD_YTM_SESSION_FILE=… xcrun simctl launch …`. 실기기용 세션 획득은 미정.
- Domain 변경: `Artwork`(fixture theme | remote URL), `Track.duration`/`Release.kind`/`year`/`artistID` optional.
- **A1 Home [확인, Simulator]**: live Home = continuation 포함 4–5 요청, 13–15 shelf, ~2.4 s. 서버 제목·순서 그대로, `빠른 선곡`만 H1에 따라 맨 위로. 빠른 선곡은 web 응답에서 **마지막 page**에 있고 식별자는 지역화 제목뿐(`빠른 선곡`/`Quick picks`). 목록형 shelf는 서버 `numItemsPerColumn`(4)로 가로 paging. 오류 상태(세션 파일 거부, `logged_in=0` 만료) + 다시 시도 확인. Mock 모드 Home은 이전과 동일.
- A1 남은 차이: podcast/episode 항목 미표시, Home 곡 duration 없음(0:00), player backdrop는 remote art일 때 고정색, Release/Artist/Playlist 상세는 live id면 "아직 연결되지 않은 페이지".
- **세션 만료 전제 [확인]**: 2026-09-28 원본 브라우저에서 로그아웃하자 저장된 cookie 파일이 무효화됨(재로그인 후 새 파일로 교체, `logged_in=1` 재확인). 설계 반영:
  - credential은 `SessionCredentialStore`(actor)를 통해서만 사용. 서버가 거부(`logged_in=0`, HTTP 401/403)하면 그 파일 버전(mtime)을 rejected로 기록하고 **같은 버전으로는 더 요청하지 않음**. 같은 경로의 파일이 교체되면 다음 요청에서 다시 읽음(앱 재시작 불필요). 익명 요청으로 몰래 fallback하지 않음.
  - UI에는 `CatalogError.signedOut`("세션 만료/로그아웃, 갱신 후 다시 시도")만 보임.
  - 실기기 production에서는 파일 대신 앱 내 로그인에서 얻은 세션이 같은 store 자리에 들어가야 함 [미구현, 방식 미정].
- **Replay 모드 (debug build)**: `YTM_REPLAY_DIR`(저장소 밖)의 `manifest.json`이 요청 키(`browse:<id>`, `browse:continuation:<token>`, `search:<query>:<params>`)를 redacted 응답 파일에 매핑. 계정 요청 없이 parser·UI 검증용. 녹화 없는 요청은 `notRecorded` 오류. 녹화 응답은 계정 데이터(청취 기록 등)를 담으므로 commit하지 않음.
- **A2 Search [확인, Simulator, 새 세션]**: live "iu" 검색 — 상단 아티스트 카드, 노래/싱글/EP/앨범/재생목록/아티스트 행, 노래·재생목록 필터가 서버 필터 응답(`musicShelfRenderer`)으로 동작. Mock 검색 결과 이전과 동일. 만료 처리 runtime 확인: 가짜 cookie → 1회 요청 후 rejected, 다시 시도 2회는 **요청 없음**, 같은 경로 파일 교체 후 다시 시도는 새 요청 1회. `MusicCatalog.search(_:filter:)`. 필터는 서버 chip params(ytmusicapi와 같은 상수), UI의 "재생목록"은 서버 "추천 재생목록"에 매핑(커뮤니티 재생목록 chip 없음). 결과: 상단 카드(`musicCardShelfRenderer`) + 결과별 `itemSectionRenderer` 행, 중복 제거. 입력은 300 ms debounce, 입력이 바뀌면 이전 요청 취소. 보관함 scope는 Library 단계까지 로컬 fixture 필터 유지.
- **A3 Release [확인, Simulator, live]**: `MusicCatalog.release(_:)` → `ReleaseDetail`(release, tracks, server shelves). 공용 `CatalogPage` 로더(로딩/오류/다시 시도). 실제 응답 기준 반영: 헤더 `subtitle`("앨범 • 2017년") → kind·year, 아티스트는 `straplineTextOne`; 트랙 행은 아티스트 열이 비어 있어 앨범 아티스트로 채움, 행 thumbnail 없음 → 앨범 art; 하단 shelf는 서버 제목(`맞춤 발표곡`, 다른 아티스트 포함)으로 표시, 싱글은 shelf 없음. 앨범(Palette)·EP(Love poem, shelf에서 중첩 이동)·싱글(이 별로부터) 확인, footer "10곡, 39분"이 서버 `secondSubtitle`과 일치. 이번 응답들에 unplayable 트랙은 없었음 → 표현 미반영. 검색 결과로 돌아올 때 재요청하던 문제 수정(같은 query·filter면 재사용). Mock release 페이지 동일, replay의 미녹화 앨범에서 오류 상태 확인.
- **A4 Artist [확인, Simulator, live]**: `MusicCatalog.artist(_:)` → `ArtistDetail`(artist, 서버 순서 섹션 `.songs`/`.items`, `radioPlaylistID` RDEM…, `shufflePlaylistID` RDAO…). 실제 응답 기준 반영: header `musicImmersiveHeaderRenderer`, 믹스/셔플은 `watchEndpoint.playlistId`(예전 `watchPlaylistEndpoint` 아님); `description`은 아티스트마다 있거나 없음(아이유 없음 → 정보 버튼 숨김, AKMU 있음 → 시트 표시); hero 이미지는 와이드 배너(최대 2880×1200)라 리사이즈하지 않음; 인기곡 행의 앨범은 **4번째 열** → 앨범 열 탐색을 모든 열로 일반화; `앨범` shelf 카드는 연도만 있어 페이지 아티스트로 귀속. 섹션: 인기곡, 앨범, 싱글 및 EP, 동영상, 라이브 공연 영상, 추천 콘텐츠, <아티스트>의 재생목록, 팬이 좋아할 만한 다른 아티스트(모두 서버 제목). 확인: 검색→아티스트, 아티스트→유사 아티스트(AKMU), 인기곡 메뉴 "앨범으로 이동"→Release, 재생 버튼(mock radio), Mock Glass Orchard 동일, replay 미녹화 오류 상태. 섹션 "더보기" endpoint(전체 곡 VLOLAK…, 디스코그래피 MPAD…)는 기존 UI에 chevron이 없어 미연결.
- **A5 Playlist [확인, Simulator, live]**: `MusicCatalog.playlist(_:)` → `PlaylistDetail`(playlist, 첫 페이지 tracks, 서버 `summary`, `next`) + `playlistPage(_:)`(continuation). 실제 응답 기준 반영:
  - 행은 `musicPlaylistShelfRenderer`에 **100개씩**, 끝에 `continuationItemRenderer.continuationEndpoint.continuationCommand.token`; 다음 페이지는 `browse {continuation}` → `onResponseReceivedActions[].appendContinuationItemsAction.continuationItems`. 좋아요 1,110곡 끝까지 연결 확인(11회).
  - 종류는 header subtitle 첫 부분(`자동 재생목록`/`믹스`/`재생목록`) 우선; ID 규칙 수정: `RDCLAK…`은 편집 재생목록(믹스 아님).
  - 소유자 이름은 `facepile.avatarStackViewModel.text.content`에만 있음(편집·일부 믹스 = "YouTube Music"; 사용자 재생목록·좋아요는 없음) → 빈 경우 header 부제 생략, footer는 "재생목록 · 나"로 가정하지 않고 "재생목록".
  - 사용자 재생목록 행은 재생시간이 flex 열에 있음 → duration 탐색 확장(`m:ss` 형식만).
  - **unplayable**: `musicItemRendererDisplayPolicy = GREY_OUT`(사유 텍스트 없음) → `Track.isPlayable`; SongRow 흐리게 + 재생 비활성, 셔플/재생 목록에서 제외.
  - footer 곡 수/길이는 서버 `secondSubtitle`("1,110곡 • 6시간 이상") 사용(페이지 일부만 로드되므로).
  - 확인: 편집(Presenting 아이유, 소유자 표시·저장 버튼), 좋아요(자동, 다운로드 자리), 사용자(Made in Japan, 430곡, 62번째 greyed 행 흐리게 표시, 스크롤 끝에서 continuation 1회), 믹스(보관 콘텐츠 믹스), Mock 좋아요 재생목록 동일.
  - 검증 중 발견·수정: (1) 행 컨테이너가 `VStack`이라 마지막 행 onAppear가 즉시 연쇄 → 전체 페이지 자동 로드 → `LazyVStack`으로 수정 후 1회만. (2) Home 탭 복귀 시 Home 5요청 재발생 → 로드된 feed 유지(다시 시도만 재로드), 탭 왕복 후 추가 요청 0 확인.
  - A5 미확인 항목 재검증(A6 중) [확인]: greyed 행 탭 → 재생 안 됨(ASMR 재생목록, 98/100행이 서버 GREY_OUT); live footer 서버 summary 표시("조회수 9회 • 트랙 2개 • 4분 28초"); 소유권 판별 → 아래 A6.

- **A6 Library [확인, Simulator, live]**: `MusicCatalog.library()` → `LibraryFeed`(pinned, recent), `library(_ category)` / `libraryPage(_:)` → `LibraryPage`(items, next). 실제 응답 기준 반영:
  - 루트 = `FEmusic_library_landing`(gridRenderer, 최근 활동 순). **고정** 여부는 카드의 `subtitleBadges`(icon `KEEP`, "고정됨")로만 표시 → 고정 항목은 상단 그리드, 나머지는 최근 활동. 이 계정은 고정 1개(좋아요 표시한 음악).
  - 카테고리: 재생목록 `FEmusic_liked_playlists`(grid, 첫 항목 "새 재생목록" 액션은 제외), 노래 `FEmusic_liked_videos`(shelf, 첫 행 "모두 셔플" 액션 제외), 앨범 `FEmusic_liked_albums`, 아티스트 `FEmusic_library_corpus_track_artists`(보관함 곡의 아티스트, "27곡" 부제). 구독 아티스트(`FEmusic_library_corpus_artists`)는 별도 endpoint이며 기존 UI에 해당 카테고리가 없어 미사용.
  - 보관함 아티스트 행은 `MUSIC_PAGE_TYPE_LIBRARY_ARTIST` + browseId `MPLA<채널ID>` → 앱은 채널 ID의 아티스트 페이지로 이동(Radwimps 확인).
  - 페이징: 첫 페이지 `gridRenderer`/`musicShelfRenderer`의 `continuations.nextContinuationData`, 다음 페이지는 `continuationContents.gridContinuation`/`musicShelfContinuation`. **continuation이 이전 페이지 항목 일부를 반복**(재생목록 26+18 중 5개 중복) → id 기준 중복 제거.
  - **재생목록 소유권**: 보관함 카드 메뉴에 `EDIT` → 내 것, `BOOKMARK`/`BOOKMARK_BORDER`(저장 토글) → 남의 것. 재생목록 페이지는 **내 재생목록이면 header가 `musicEditablePlaylistDetailHeaderRenderer.header.musicResponsiveHeaderRenderer`로 감싸져** 옴(기존 parser가 이 형태를 못 읽어 오류 → 수정). `Playlist.isOwned`(nil = 모름, fixture는 kind로 추론) → 내 것이면 다운로드 자리·footer "재생목록 · 나", 남의 것이면 저장(+) 버튼.
  - 카드 부제에서 곡 수("트랙 479개", "50곡")를 소유자로 오인하던 문제 수정.
  - 확인: 루트(고정·최근 활동), 재생목록(스크롤로 continuation, 중복 없음), 노래, 앨범(1), 아티스트→아티스트 페이지, 내 재생목록(보카로인 곡들 모아둠, [?]?), 남의 재생목록(ASMR, 저장 버튼), 요청 수(Home 5 + 보관함 1 + 재생목록 1, 불필요 요청 없음), Mock Library 동일, replay 미녹화 시 오류 상태.
  - 미반영: 정렬(서버 header의 정렬 메뉴: 최근 활동/최근에 저장됨/최근 재생), 보관함 검색 scope(여전히 로컬 fixture 필터), 고정/저장/좋아요 등 쓰기 동작(요청 없음, 기존 세션 상태 UI 유지).

#### A6.5 Library semantics audit (조사만, 코드 변경 없음)
**1. 보관함 검색** [확인, live]
- 서버 endpoint 있음: 검색 응답의 `tabbedSearchResultsRenderer.tabs`에 `YT Music` / `보관함`(`searchEndpoint.params = agIYBA==`) / `업로드`(`agIYAw==`) 탭이 서버에서 온다. 보관함 탭 결과는 `musicShelfRenderer`로 아티스트·앨범·노래·재생목록 shelf, 결과에 따라 chip(아티스트 `EgWKAQIgAWoIEAUQCRADGAQ=`, 앨범 `…IYAWoI…`, 노래 `…IIAWoI…`)이 붙는다. 결과 없음은 `messageRenderer`("검색결과가 없습니다.").
- 범위 검증: 보관함 아티스트(Radwimps, `MUSIC_PAGE_TYPE_LIBRARY_ARTIST`), 저장 앨범(君のように生きれたら), 보관함 노래(Lovebird), **내가 만든 재생목록**(보카로인 곡들 모아둠) → 찾음. **남이 만든 저장 재생목록**(ASMR)과 그 안에만 있는 곡(Motteke) → **없음**.
- 판단: 최종 경로로 사용 가능(서버가 공식 web client와 같은 보관함 검색을 수행, 로드된 page 필터링 불필요). 단 "보관함 화면에 보이는 모든 것"과 범위가 다름(저장한 남의 재생목록 제외) — UI 문구/기대치에 반영 필요. params는 `SearchParsing`에 하드코딩하지 말고 응답의 탭 endpoint 값을 쓰는 편이 안전.

**2. Pin 의미** [확인, live + 저장 응답]
- 응답에 존재하는 pin은 하나: **"다시 듣기에 고정 / 다시 듣기에서 고정 해제"** (`toggleMenuServiceItemRenderer`, icon `KEEP`/`KEEP_OFF`, 양방향 모두 `feedbackEndpoint.feedbackToken`). 재생목록/앨범/아티스트/노래 카드 메뉴와 재생목록 header에 공통.
- **"빠른 선곡에 고정" action은 어떤 응답에도 없음.** Home 빠른 선곡 항목 메뉴에도 없음 → 기존 mock의 `QuickPick(pinned:)` 개념은 서버 근거 없음.
- 상태 판별: 메뉴 toggle의 기본 icon이 `KEEP_OFF`면 현재 고정됨. Home 다시 듣기와 보관함 메뉴는 같은 항목에 대해 일치(3개: 좋아요 표시한 음악, 몽환적인 일본 인디 락 믹스, たま★ふぁんこっと).
- **`subtitleBadges`의 `고정됨` badge는 불완전**: 보관함 landing에서 고정 3개 중 좋아요 표시한 음악에만 badge, 몽환적인 믹스는 메뉴상 고정인데 badge 없음. Home 다시 듣기에서는 3개 모두 badge. → A6 parser(badge 기준 pinned 분리)는 과소 판정. 메뉴 toggle 상태를 기준으로 바꿔야 함 [미수정].
- feedbackToken은 응답마다 값이 다름(같은 항목 다른 hash) → 캐시·재사용 금지, 최신 응답의 token만 사용.
- 보관함 landing에서 고정 항목이 앞에 오지 않음(몽환적인 믹스 13번째) → "보관함 상단 고정 그리드"는 서버 정렬 개념이 아님. 현재 UI의 pinned 그리드를 "다시 듣기 고정" 항목으로 채울지 결정 필요.
- 미확정 [가설]: badge가 좋아요에만 붙는 이유(기본 고정 표시?). 공식 앱에서 항목 하나를 pin/unpin 후 landing/home을 다시 받아 badge·메뉴·순서 변화를 비교하면 확정 가능(사용자 협조 필요, 요청 기록은 redacted로).

**3. 아티스트 vs 구독 아티스트** [확인, live]
- 현재 `아티스트` 카테고리(`FEmusic_library_corpus_track_artists`) = **보관함 노래의 아티스트**: 442명(10 page, 중복 0), 부제 "N곡", id `MPLA<채널ID>`, 해당 페이지(`MPLA…` browse)는 `musicHeaderRenderer` + 보관함에 있는 그 아티스트 곡 목록(Radwimps 28곡).
- 구독 아티스트(`FEmusic_library_corpus_artists`) = 구독 채널: 3명, 부제 "구독자 N명", id `UC…`, `MUSIC_PAGE_TYPE_ARTIST`.
- 겹침 1명, 구독만 2명(보관함 곡 없음). 다른 개념. 합치면 "N곡"과 "구독자" 메타가 섞이고 탭 시 목적지(보관함 곡 목록 vs 아티스트 페이지)가 다름. 현재 앱은 `MPLA`→채널 아티스트 페이지로 이동(보관함 곡 목록 페이지는 미사용). UI 결정 대기.
- 참고: 노래 카테고리(`FEmusic_liked_videos`)는 좋아요 목록과 대부분 겹치지만 동일하지 않음(첫 25곡 중 24곡이 좋아요 첫 100곡에 포함) → "보관함 노래 = 좋아요 + 보관함에 저장한 곡" [가설].

**4. Write action inventory** [확인: 응답의 endpoint 형태 / 가설: 실제 HTTP 경로는 외부 참고(ytmusicapi), 미관찰]
| action | 응답 표현 | 되돌리기 | 성공 후 무효화 |
|---|---|---|---|
| 곡 좋아요 / 취소 | `likeEndpoint{status LIKE/INDIFFERENT, target.videoId}` (메뉴 toggle, `likeButtonRenderer.serviceEndpoints`) | 가능 | 좋아요 재생목록(VLLM), 보관함 노래, 해당 행 상태 |
| 재생목록/앨범 보관함 저장 / 해제 | `likeEndpoint{LIKE/INDIFFERENT, target.playlistId}` (메뉴 "보관함에 재생목록/앨범 저장", 재생목록 header toggle) | 가능 | 보관함 landing·재생목록/앨범 카테고리·보관함 검색·header 버튼 |
| 믹스 저장 | `playlistEditEndpoint ACTION_SET_EPHEMERAL_STATUS` (양방향) | 가능 | 보관함 재생목록 |
| 곡 보관함에 저장 / 삭제 | `feedbackEndpoint` token 쌍 (노래 행 메뉴 "보관함에 저장") | 가능(토큰) | 보관함 노래·보관함 아티스트·보관함 검색 |
| 다시 듣기 고정 / 해제 | `feedbackEndpoint` token 쌍 | 가능(토큰) | Home 다시 듣기, 보관함 landing |
| 아티스트 구독 / 취소 | `subscribeEndpoint`/`unsubscribeEndpoint{channelIds}` (메뉴 toggle, `subscribeButtonRenderer.serviceEndpoints`) | 가능 | 구독 아티스트, 아티스트 header |
| 재생목록에서 곡 삭제 | `playlistEditEndpoint ACTION_REMOVE_VIDEO` (내 재생목록), 좋아요 목록에서는 `likeEndpoint INDIFFERENT` | 부분적(다시 추가 필요, 위치 복원 불확실) | 해당 재생목록 |
| 재생목록 삭제 | `confirmDialogEndpoint` → `deletePlaylistEndpoint` | **불가** | 보관함 전체 |
| 관심 없음 / 추천 안 함 | `feedbackEndpoint` 단방향 | 불가(응답에 역방향 없음) | Home |
| 새 재생목록 | `createPlaylistEndpoint` (보관함 재생목록 첫 항목) | 삭제로만 | 보관함 |
- 공통: 토큰·target은 **최신 응답에서만** 취하고, 성공 응답 전에는 UI를 낙관적으로 바꾸더라도 실패 시 되돌리기 필요. 현재 UI의 쓰기 버튼(보관함 저장 +, 아티스트 ☆, 곡 즐겨찾기)은 로컬 세션 상태만 바꿈.

#### A6.6 Home "빠른 선곡" semantic mapping [확인: WEB_REMIX 응답 구조 + 사용자 iOS 스크린샷 `references/screenshot/ytm-home-quick-picks.png`]
제목이 아니라 구조로 비교(Home 5 page, 15 shelf):
| | WEB_REMIX `다시 듣기` (위치 0) | WEB_REMIX `빠른 선곡` (위치 10) | iOS 첫 `빠른 선곡` (3×3) |
|---|---|---|---|
| renderer | `musicCarouselShelfRenderer`, `musicTwoRowItemRenderer` 20개 | 같은 carousel, `musicResponsiveListItemRenderer` 20개, `numItemsPerColumn` 4 | 3×3 페이지 그리드, 점 3개(≈20개) |
| 항목 종류 | 혼합(재생목록 3, 곡 ATV 10, 동영상 UGC 7) | 곡만(ATV 17, OMV 3) | 혼합(믹스·재생목록·곡·동영상) |
| header | 사용자 채널 thumbnail("채널로 이동", `USER_CHANNEL`), 더보기 → `browse FEmusic_listen_again`(페이지 제목 "다시 듣기", 46개 grid) | thumbnail 없음, 더보기 = "모두 재생" watch | 아바타 + chevron |
| 고정 | 앞 3개가 `KEEP_OFF`(고정됨) + `고정됨` badge: 몽환적인 일본 인디 락 믹스, たま★ふぁんこっと, 좋아요 표시한 음악 | 없음 | 앞 3개에 pin 아이콘, **같은 3개·같은 순서**, 이어서 パスワードキーパー, [Adult Swim]…, Cheer squad… (web 목록과 일치) |

결론:
- **iOS 첫 `빠른 선곡`(3×3) = WEB_REMIX `다시 듣기` 모듈(`FEmusic_listen_again`)**. 같은 데이터에 client별로 다른 제목. iOS의 pin 아이콘 = "다시 듣기에 고정" 상태(`KEEP_OFF`). 이 모듈에서는 고정 항목이 앞에 온다.
- **iOS 두 번째 `빠른 선곡`(그리드 아님) = WEB_REMIX `빠른 선곡`**(곡 목록, 4행 column, 모두 재생) [사용자 관찰 기준, 항목 대조는 미실시].
- "다시 듣기에 고정/해제" toggle은 Home의 **모든** 카드/행에 붙어 있다(154개). 고정되면 이 모듈 앞쪽에 나타난다. 별도의 "빠른 선곡에 고정" action은 없다 — iOS의 "빠른 선곡 pin"과 이것이 같은 상태.
- 보관함 `고정됨` badge는 같은 pin 상태의 불완전한 표시(A6.5-2).
- 현재 앱 live Home은 **반대로 연결됨**: web `빠른 선곡`(곡 목록)을 3×3 그리드로 올리고, `다시 듣기`는 일반 카드 shelf로 표시. H1("빠른 선곡 우선")이 참고한 iOS 3×3는 실제로 listen-again 모듈이다.
- 식별은 지역화 제목 대신 구조로: listen-again = 더보기 `browseId == FEmusic_listen_again`(비지역화), 곡 빠른 선곡 = list item + `numItemsPerColumn` + 모두 재생 watch(제목 fallback). [미수정 — 결정 대기]
- **적용 (사용자 결정 반영)** [확인, Simulator live]:
  - 3×3 그리드 = listen-again 모듈(식별: 더보기 `browseId == FEmusic_listen_again`). 혼합 항목(`QuickPick`에 artist·track pinned 추가), 서버 순서 유지(고정 항목 선두), pin 아이콘 표시. live 첫 행 = 몽환적인 일본 인디 락 믹스 · たま★ふぁんこっと · 좋아요 표시한 음악(모두 pin) — **iOS reference의 고정 3개·순서와 일치**. 이어지는 항목은 시점 차이로 reference와 일부 다름.
  - 곡 목록 모듈은 서버 위치 그대로 row 기반 가로 shelf(4행). 식별: `numItemsPerColumn` + 헤더 "모두 재생" watch + **모든 행의 재생 endpoint가 그 곡의 radio(`playlistId == RDAMVM<videoId>`)**. 같은 형태의 "Shorts에서 들은 음악"은 videoId만 재생해서 구분됨(표본 2개). `shelfId`는 응답마다 새 UUID라 식별자로 못 씀.
  - 표시 제목은 iOS 기준: 두 모듈 모두 "빠른 선곡". 그 외 shelf는 서버 제목.
  - **미검증**: 곡 목록 모듈 ↔ iOS 두 번째 "빠른 선곡"의 항목 단위 대응(사용자 관찰만).
  - 보관함 고정 판정을 badge → 메뉴 toggle(`KEEP_OFF`) 기준으로 변경, badge는 toggle이 없을 때만 fallback. live 보관함 고정 1개 → 2개(좋아요 표시한 음악, 몽환적인 믹스); 세 번째 고정(たま★ふぁんこっと, 동영상)은 보관함 landing 응답에 없음.
  - Mock Home/보관함 동일.

#### A6.7 Library 읽기 마무리 [확인, Simulator live/mock/replay]
- **보관함 검색 = 서버 scope**: `MusicCatalog.search(_:filter:scope:)`. live 보관함 scope는 검색 응답의 보관함 탭 params(`agIYBA==`), 필터는 그 탭의 chip params(노래 `EgWKAQIIAWoIEAUQCRADGAQ=`, 앨범 `…IYAWoI…`, 아티스트 `…IgAWoI…`). 재생목록 chip은 보관함 탭에서 관찰되지 않아 탭 결과를 재생목록 종류로만 좁힘. 결과는 응답의 **selected 탭**에서 읽음(이전엔 tabs[0] 고정). 남이 만든 저장 재생목록 제외는 서버 semantics 그대로(보정 없음). 로컬 fixture 필터와 `MockLibrary` 의존 제거. Mock은 fixture 보관함 항목만 검색(자기 재생목록만).
  - live: "Miku" → 아티스트 Satsuki, 앨범 2, 노래 2(A6.5 조사와 동일); 노래 필터 → 2곡; "ASMR" → 결과 없음. replay 미녹화 → 오류·다시 시도.
- **아티스트 두 domain**: `LibraryArtistScope`(`.library` = `FEmusic_library_corpus_track_artists`, "N곡" / `.subscribed` = `FEmusic_library_corpus_artists`, "구독자 N명"). `Artist.byline`에 목록의 서버 부제를 보존. 아티스트 화면 상단 segmented `보관함 / 구독`(`safeAreaInset`이라 목록 로딩 중에도 유지), 목록은 scope별 `CatalogPage`.
  - 선택 이유: 보관함 root 구조를 바꾸지 않고, 둘 다 "아티스트"라서 같은 화면에서 비교·전환이 자연스럽다. 별도 category 행은 root를 바꾸고, 합친 목록은 부제·의미가 섞인다.
  - 흐름 확인: 보관함 → 아티스트(442명, "27곡") → 구독(3명, "구독자 …") → 아티스트 페이지 → 뒤로 시 선택한 scope 유지. 보관함 아티스트 탭도 채널 아티스트 페이지로 이동(MPLA 보관함 곡 목록 페이지는 여전히 미사용). Mock 구독 2명(fixture).
- write action은 미구현(A6.5-4 inventory 유지).

#### A7 Queue [확인, Simulator live/mock/replay; playback은 여전히 mock]
- Domain(`Domain/Queue.swift`): `QueueItem { id(=playlistSetVideoId), primary: QueueVariant{track, kind(song/officialVideo/userVideo)}, counterpart: QueueVariant?, segmentMap: SegmentMap?, unplayableReason }`, `SegmentMap`(primary↔counterpart 위치 변환 양방향), `QueuePage { items, selectedIndex, next: CatalogContinuation?, isInfinite }`, `QueueSeed { radio(track) | list(playlistID?, tracks, start) | artist(playlistID?, songs) }`. `MusicCatalog.queue(_:)` / `queuePage(_:)`.
- `/next` 매핑 [확인]: 요청 `{videoId?, playlistId, params?, isAudioOnly, enablePersistentPlaylistPanel}`. 곡 믹스 = `RDAMVM<videoId>` + `params wAEB`; 앨범 = `OLAK5uy_…` + 시작 videoId(선택 항목이 탭한 곡); 재생목록 = `VL` 제거한 id; 아티스트 재생 = header의 `RDEM…`(videoId 없이, 서버가 첫 곡 선택). 응답 `playlistPanelRenderer.contents`는 `playlistPanelVideoRenderer` 또는 `playlistPanelVideoWrapperRenderer{primaryRenderer, counterpart[0]{counterpartRenderer, segmentMap.segment[]}}`, 현재 항목은 `selected`. continuation: radio/mix = `nextRadioContinuationData`(무한, 49개/page), 재생목록 = `nextContinuationData`; 요청은 `{continuation}`만으로 충분. `automixPreviewVideoRenderer`(앨범 끝 자동 믹스 안내)는 항목 아님 → 무시 [미구현: 앨범 뒤 자동 믹스 이어붙이기].
- Unplayable: `unplayableText`("[거주 국가에서 차단된 동영상]", title 없음)는 **anonymous 응답에서만 관찰**. 로그인 세션에서는 같은 항목이 재생 가능했고, 보관함에서 GREY_OUT인 곡(A5)은 `/next` 대기열에서 **아예 빠짐**(4 page 확인). 모델·UI(흐림, 선택 불가, next/previous 건너뜀)는 구현했지만 live 화면에서 unplayable 대기열 항목은 **미확인**.
- Player 상태(`MockPlayer`, 이름 유지): 선택 즉시 탭한 곡 표시 → 서버 queue 도착 시 교체(서버 `selected` 항목, 재생 불가면 첫 재생 가능 항목, 전부 불가면 탭한 곡 유지 + 뒤에 표시). 새 요청이 이전 요청 결과를 덮지 않음(task cancel). shuffle/reorder는 `QueueItem` 단위(원래 서버 순서 보존), continuation은 목록 끝 도달 또는 next로 남은 항목 <5일 때 1회, id로 중복 제거. 곡 전환 버튼 = counterpart 있는 항목에서만 활성, 위치는 `SegmentMap`으로 변환(오디오 없음). 비활성 queue 옵션을 흐리게 표시(기존에는 비활성도 활성처럼 보였음).
- 확인: live 검색 → Celebrity 믹스(서버 대기열·출처·길이 3:16), 0:59에서 곡 전환 → 영상 1:01/3:18(segmentMap +2.237 s와 일치) → 되돌림 0:59; 대기열 항목 선택; 아티스트 재생 → 서버 `RDEM` 믹스(첫 곡 마음); 대기열 끝 스크롤 → continuation 요청 1회; Full Player 닫기 → Mini Next → 다시 열기 시 현재 곡·Queue 모드·출처·순서 유지; replay에서 anonymous 응답 → 대기열 오류·다시 시도, 탭한 곡 유지·Next 비활성; Mock 대기열 동일.
- **추가 검증 (2026-09-29)** [확인, Simulator]: live 앨범(Palette) 8번 곡 탭 → `next` 1회, 서버 `selected` = 밤편지, 다음 9–10번, 출처 Palette; 곡 전환 0:00 → 영상 0:24(segmentMap +24.013 s) → Next = 그렇게 사랑은(0:00, 곡 전환 비활성) → Previous = 밤편지 노래(영상 상태 해제); live 재생목록(보카로인 곡들 모아둠) 3번 곡 → 서버 대기열·출처; 셔플 on → 순서 변경, off → 서버 순서 그대로 복원; 첫 항목을 드래그해 3번째로 이동 → Next가 바뀐 순서를 따름; replay에서 대기열 파일 없음 → 오류 행 → 파일 복구 후 다시 시도 → 대기열 로드·오류 행 사라짐.
- **미검증 유지**: unplayable 대기열 항목 화면(로그인 응답에서 재현 불가). 오류 문구가 replay에서는 시스템 파일 오류 원문(영어)으로 보임 — live 오류는 `CatalogError` 문구.
- 보류(미구현, blocker 아님): 앨범 끝 automix, 대기열 저장·재시작 복원(현재 앱 재시작 시 초기화). native player가 `QueueItem`(primary/counterpart/segmentMap)을 직접 소비하도록 연결(B축 결과 이후).

#### A8 사전 조사 메모 (2026-09-29, 코드 변경·쓰기 요청 없음, 저장 응답에서 형태만 확인)
- 곡 좋아요: 메뉴 toggle `FAVORITE`/`UNFAVORITE`, `likeEndpoint{status LIKE|INDIFFERENT, target.videoId, likeParams|removeLikeParams}`. `/next`의 `likeButtonRenderer{likeStatus}`에 현재 상태, LIKE 시 `musicLibraryStatusUpdateCommand`(보관함 추가 feedback token) 동반.
- 앨범/재생목록 저장: header `toggleButtonRenderer{isToggled, defaultIcon BOOKMARK_BORDER, default/toggled likeEndpoint target.playlistId}`.
- 믹스 저장: `playlistEditEndpoint{playlistId, actions[ACTION_SET_EPHEMERAL_STATUS isEphemeral]}`.
- 곡 보관함 저장·다시 듣기 고정: toggle `BOOKMARK_BORDER`/`KEEP`, 양방향 `feedbackEndpoint.feedbackToken`(응답마다 다름 → 최신 응답에서만 사용).
- 구독: `subscribeButtonRenderer{subscribed, channelId, serviceEndpoints[subscribeEndpoint{channelIds, params}, signalServiceEndpoint → confirmDialog → unsubscribeEndpoint{channelIds}]}`.
- HTTP 경로(`like/like`, `like/removelike`, `feedback`, `subscription/subscribe|unsubscribe`, `browse/edit_playlist`)는 [가설, 미관찰] — A8에서 한 항목씩 원상태 기록 → 실행 → 확인 → 되돌림으로 검증 예정. (`like/*`, `feedback`은 A8.1에서 확인)

#### A8 Write Actions — 공통 구조
- Domain: `LibraryEdit`(각 case는 정확한 역연산이 있는 action만) → `MusicCatalog.apply(_:) -> Set<CatalogScope>`. 반환값은 **서비스가 판단한 영향 범위**(`.playlist(id)`, `.library` = 보관함 root·카테고리·보관함 검색). `CatalogChanges`(MainActor, scope별 revision)가 성공한 write의 scope만 올림.
- 캐시를 가진 화면은 자기 scope revision이 바뀌면 **제자리 재로드**(실패 시 기존 내용 유지): `CatalogPage(scope:)`(재생목록 `.playlist(id)`, 보관함 카테고리 `.library`), `LibraryView`(`.library`), 보관함 scope 검색(request key에 revision). Home은 좋아요에 영향 없음 → 대상 아님.
- 요청 body는 id만(토큰 저장·재사용 없음). 토큰이 필요한 action(feedback)은 실행 직전 최신 응답에서 가져오는 구조로 추가 예정.
- 검증 도구: probe `raw`로 action 전후 상태(`/next` likeStatus, VLLM 첫 page·곡 수, `FEmusic_liked_videos` 첫 page, 보관함 검색)를 저장·비교(scratchpad `a8/state.sh`, 저장소 밖).

#### A8.1 곡 좋아요 / 취소 [확인, 실제 계정 + Simulator live/replay/mock, 원상복구 확인]
- 경로 [확인]: `like/like` / `like/removelike`, body `{target:{videoId}}`(`likeParams` 없이도 200). 응답 = toast action만(`좋아요 표시한 음악에 저장되었습니다.` / `…에서 삭제되었습니다.`), `logged_in=1`.
- probe 검증(보라빛 밤 `wh7j1uEpNsQ`, ATV): 원상태 INDIFFERENT·좋아요 1,111곡·보관함 노래/검색 없음 → like: LIKE, VLLM 첫 항목, 1,112곡, **보관함 노래 첫 항목·보관함 검색에도 추가** → removelike: INDIFFERENT, 1,111곡, 보관함 검색 없음, 그러나 **보관함 노래(`FEmusic_liked_videos`)에는 남음**(1분 후에도). web client의 INDIFFERENT endpoint에도 보관함 제거 action이 없음 → 서비스 동작 [확인]. 원상복구를 위해 최신 `FEmusic_liked_videos` 응답의 해당 행 `보관함에서 삭제` feedback token으로 `feedback {feedbackTokens:[…]}` 1회(응답 `isProcessed: true`, toast `보관함에서 삭제되었습니다.`) → 보관함 노래 첫 page·VLLM 첫 page가 **원 응답과 id 순서까지 동일**.
  - 참고: 원래 보관함 노래 첫 page 25곡 중 좋아요에 없는 1곡(うそのお言葉)도 같은 잔여물일 가능성 [가설]. 보관함 노래 행 메뉴의 `보관함에 저장` toggle은 좋아요로 들어온 곡에서도 기본값 "저장"(= 명시 저장 아님)이라 보관함 포함 여부 판정에 쓸 수 없음.
- 앱: Full Player의 별(즐겨찾기) = 서비스 좋아요. 초기 상태는 `/next` 대기열 행 메뉴 toggle(`UNFAVORITE` = 현재 좋아요)로 `QueueVariant.isLiked`에 기록(counterpart 포함). 탭 → 즉시 반영 → 실패 시 되돌림(+ `Player` 로그), 진행 중 재탭 무시, 진행 중인 id는 queue page가 덮어쓰지 않음. live unlike는 web과 같이 `removelike`만(보관함 노래 잔여는 서비스 동작 그대로 둠).
- Simulator live(지구가 태양을 네 번 (Live) `UCQHgJ4uRwo`, UGC 영상): 원상태 INDIFFERENT·1,111곡 → 별 탭 → `like/like` 1회, 별 채움, 서버 LIKE·VLLM 첫 항목·1,112곡(이 영상은 보관함 노래에 **추가되지 않음** — ATV와 다름) → 좋아요 표시한 음악 페이지 첫 행 + 행 별 표시 → 그 페이지를 연 채 Full Player에서 별 해제 → `like/removelike` 1회 + 열린 VLLM 페이지 `browse` 재로드 1회, 목록에서 즉시 사라짐 → 서버 INDIFFERENT·1,111곡, VLLM·보관함 노래 첫 page가 원 응답과 동일.
- replay: write 녹화 없음 → `notRecorded` → 별 즉시 되돌림, 로그 `like write failed, reverted`. Mock: 별 토글 유지(세션 한정), 요청 없음.
- 미확인: 오류 시 사용자에게 보이는 문구 없음(되돌림만) — 필요 여부는 UI 결정. 행 메뉴에서의 좋아요(SongRow 메뉴)는 기존 UI에 항목이 없어 미연결.

#### A8.2 앨범 보관함 저장 / 해제 [확인, 실제 계정 + Simulator live/mock, 원상복구 확인]
- 경로 [확인]: 곡 좋아요와 같은 `like/like` / `like/removelike`, body `{target:{playlistId: <OLAK5uy_…>}}`. 응답 toast `보관함에 저장됨` / `보관함에서 삭제되었습니다.`
- 상태 원천: release header `toggleButtonRenderer`(defaultIcon `BOOKMARK_BORDER`, `isToggled`, default/toggled `likeEndpoint.target.playlistId`) → `ReleaseDetail.membership = LibraryMembership(listID, isSaved)`. 재생목록 header의 같은 toggle도 같은 parser로 `PlaylistDetail.membership`(내 재생목록은 nil) — 계정 검증은 A8.3.
- probe(Palette `MPREb_WOciJ8HA7tx`): 원상태 toggle off·보관함 앨범 [君のように生きれたら]·landing에 없음·보관함 검색 없음 → 저장: toggle on, 앨범 [Palette, 君の…], **landing 1번 위치**(첫 page 25개 유지, 기존 1개가 밀려남), 보관함 검색 Palette → 해제: 모든 항목 원상태, **landing 첫 page id 순서까지 원 응답과 동일**.
- 앱: `LibrarySaveButton(membership:)` — 탭 즉시 아이콘 전환, 실패 시 되돌림, 진행 중 재탭 무시. `apply(.save(listID:, Bool))` → `[.library]`. `MockLibrary`(세션 전용 flag) 제거 → Mock catalog가 `Mutex` 저장 집합으로 release/playlist `membership`, 보관함 앨범·재생목록 카테고리, 보관함 검색에 반영.
- Simulator live: 보관함 root를 먼저 로드 → 검색 → Palette(+, 서버 상태와 일치) → + 탭 → `like/like` 1회, ✓ → 서버 저장 확인 → Library 탭 복귀 시 root `browse` 1회 재로드, 최근 활동 첫 항목 Palette → 앨범 카테고리(Palette 포함) → Palette 페이지(새 로드, ✓) → ✓ 탭 → `like/removelike` 1회 + 열려 있던 앨범 카테고리 `browse` 1회 재로드, Palette 사라짐 → 서버 원상태·landing 동일.
- Mock: 보관함 EP(Room for Echoes) ✓ → 해제 → 보관함 앨범 카테고리에서 제외(5 → 4). Mock 보관함 root의 고정 그리드는 별도 fixture라 변화 없음.
- replay 오류 경로는 좋아요(A8.1)와 같은 되돌림 구조, 저장 버튼 자체로는 미실행.

#### A8.3 (남의) 재생목록 보관함 저장 / 해제 [확인, 실제 계정 + Simulator live, 원상복구 확인, 코드 변경 없음]
- A8.2와 같은 경로·코드: header toggle target `playlistId`(= browseId에서 `VL` 뺀 `PL…`), `like/like` / `like/removelike`.
- 대상: IU's Palette(아이유를사랑해요, `VLPLgFYH-…`, 검색 인기 결과에서 진입 — "재생목록" 필터는 서버 추천 재생목록 chip이라 커뮤니티 재생목록이 안 나옴, A2 기록과 같음).
- probe 원상태: toggle off, 보관함 재생목록 첫 page(26)·landing에 없음 → 앱 + 탭: `like/like` 1회, ✓, 서버 toggle on·재생목록 목록 3번째·landing 2번째 → ✓ 탭: `like/removelike` 1회, +, 서버 toggle off·**재생목록 첫 page와 landing 모두 원 응답과 동일**.
- 내 재생목록은 기존대로 다운로드 자리(저장 버튼 없음, `membership` nil).

#### A8.4 아티스트 구독 / 취소 — probe만, **앱 연결 보류(attestation)** [확인, 원상복구 확인]
- header `subscribeButtonRenderer{subscribed, channelId, serviceEndpoints[subscribeEndpoint{channelIds, params}, signalServiceEndpoint→확인 dialog→unsubscribeEndpoint]}`. `channelId`는 **YouTube 채널**(아이유: 아티스트 페이지 `UCTUR0…`와 다른 `UC3SyT4…` = "이지금 [IU Official]") → YTM 구독 = YouTube 채널 구독.
- probe: 원상태 `subscribed:false`, 구독 아티스트 3명 → `subscription/subscribe {channelIds}`(params 없이) HTTP 200, toast "이지금 [IU Official] 채널을 구독합니다.", 알림 상태 entity `SUBSCRIPTION_NOTIFICATION_STATE_OFF` → 직후 읽기는 아직 이전 상태, 재조회 시 `subscribed:true`·구독 아티스트 4명(아이유 선두) → `subscription/unsubscribe {channelIds}` 200 → `subscribed:false`, 구독 아티스트 목록이 원 응답과 동일.
- **구독 응답에만 `runAttestationCommand{engagementType: ENGAGEMENT_TYPE_SUBSCRIBE, ids:[externalChannelId]}`** 포함(좋아요·저장·해제·feedback·구독 취소 응답에는 없음). web client는 이때 BotGuard 계열 attestation을 실행하는 것으로 보임 [가설]. 이번 probe는 attestation을 실행하지 않았고 서버는 구독을 적용했다. 즉 1회 attestation 없는 구독 이벤트가 계정에 기록됨.
- 판단: attestation을 실행하거나 생략하는 구현은 합의된 "보호/anti-abuse 계층" 범위.
- **사용자 결정 (2026-09-29): (c)**. attestation을 우회·생략한 구독 요청은 production 앱에 연결하지 않는다. 아티스트 ☆ 구독 버튼은 미연결(세션 표시) 유지. in-app WKWebView 로그인/session 조사에서 공식 web의 구독 흐름을 페이지 안에서 안전하게 쓸 수 있는지 함께 검토.

#### A8 공통 구조 (A8.5에서 정리)
- `LibraryActions`(MainActor, `@Observable`, 앱 root에서 한 개): 모든 쓰기의 수명주기 — 즉시 표시(`written[key]`) → 같은 key 진행 중 재탭 무시 → `catalog.apply(edit)` 성공 시 반환된 scope만 invalidate → 실패 시 이전 표시로 되돌리고 `failure` 설정. 좋아요·앨범/재생목록/믹스 저장·곡 보관함·고정 모두 이 경로(A8.1–2의 개별 구현을 대체).
- **실패 UX**: 앱 root의 시스템 `.alert`(제목 = action별 "…하지 못했습니다", 본문 = `CatalogError` 문구, 버튼 "확인") + `.sensoryFeedback(.error)`. 되돌림은 alert 전에 이미 화면에 반영.
- **token 수명**: `ServiceToggle{turnOn, turnOff: ServiceAction(token), isOn?}`은 **그 항목을 담은 응답 값 안에만** 존재(Track/HomeFeed). 쓰기 시 view가 자기 데이터의 toggle로 `LibraryEdit`를 만들어 바로 전달, `LibraryActions`는 token을 저장하지 않음. 성공 후 invalidate → 재로드된 응답의 새 token으로 다음 동작(Home 고정 → 해제에서 확인).
- 로그: `Write` category에 action 종류와 목표 상태만(id·token 없음).
- Scope: `.playlist(id)`, `.library`, `.home`(신규). Home은 `.home` revision이 바뀌면 제자리 재로드(실패 시 기존 유지).

#### A8.5 곡 보관함 추가 / 삭제 [확인, 실제 계정 + Simulator live, 원상복구 확인]
- 경로 [확인]: `feedback {feedbackTokens:[token]}` → `feedbackResponses[0].isProcessed == true`, toast `보관함에 추가되었습니다.` / `보관함에서 삭제되었습니다.` 앱은 `isProcessed`가 아니면 실패 처리.
- **상태 판별 불가 [확인]**: 행 메뉴 toggle(`BOOKMARK_BORDER` "보관함에 저장")은 보관함에 있는 곡에서도 기본값이 "저장"(검색·보관함 노래·`/next` 모두, 추가 직후 재조회 포함). `frameworkUpdates`에도 상태 없음. → `ServiceToggle.isOn = nil`(모름). 보관함 노래 목록·보관함 scope 검색 결과에서 온 곡만 `isOn = true`(`LibraryParsing.inLibrary`). 모르는 곡은 메뉴에 "보관함에 추가", 쓰기 후에는 세션의 written 상태로 "보관함에서 삭제".
- `liked`와 `inLibrary`는 별개 상태 유지(사용자 결정). 좋아요 취소는 보관함에서 자동 제거하지 않음(A8.1 semantics 그대로).
- UI: 곡 행(`SongRow`) 기존 `…` 메뉴에 `보관함에 추가 / 보관함에서 삭제`(검색 top 결과 곡 포함 — top card 메뉴에도 toggle이 있어 파싱 추가).
- probe(보라빛 밤 `wh7j1uEpNsQ`): 원상태 보관함 노래·검색에 없음, INDIFFERENT → 추가: 보관함 노래 첫 항목·보관함 검색 적중, **좋아요 INDIFFERENT 유지** → 삭제(최신 보관함 노래 응답의 toggled token): 보관함 노래 첫 page가 원 응답과 id 순서까지 동일.
- Simulator live: 검색 "pporappippam" → 첫 행 `…` → 보관함에 추가 → `feedback` 1회 → 서버 보관함 노래 첫 항목 → 같은 메뉴가 "보관함에서 삭제"로 바뀜 → 탭 → `feedback` 1회 → 서버 원상태(첫 page 동일).
- 참고: Simulator 입력 도구의 탭이 메뉴 등장 애니메이션 중이면 항목 대신 dismiss로 처리되는 경우가 있었음(두 번째 항목 좌표로 재시도해 해결) — 앱 문제 아님으로 판단 [가설, 실기기 미확인].

#### A8.6 다시 듣기 고정 / 해제 [확인, 실제 계정 + Simulator live/replay/mock, 원상복구 확인]
- 경로 [확인]: `feedback` token(`KEEP` = 고정, `KEEP_OFF` = 해제 — toggle 기본 icon이 현재 상태의 반대 action). toast `다시 듣기에 고정됨` / `다시 듣기에서 고정 해제됨`.
- probe: 고정 → `FEmusic_listen_again` 선두로 이동, 해제 → 원래 위치(5번째)로 복귀, 항목 집합·항목별 고정 상태 동일. **다시 듣기 순서의 일부 인접 swap은 쓰기 없이 연속 조회만 해도 바뀜**(q3 vs q4) → 원상복구 기준은 "집합 + 항목별 고정 상태"로 판정. 보관함 landing 고정 목록은 이 항목(곡)에 대해 변화 없음.
- UI (사용자 결정 반영): 3×3 `빠른 선곡` — tap = 재생/이동(기존), **long press = 시스템 context menu `다시 듣기에 고정 / 고정 해제`**, 별도 버튼 없음, 고정 항목은 기존 작은 pin 표시만. Home의 다른 카드 shelf(`Shelf`)도 같은 `pinContextMenu` modifier 공유(서버 toggle 있는 카드만). 목록형 곡 행은 기존 `…` 메뉴에 같은 `PinButton`. `HomeFeed.pins`(item id → toggle), `Track.pinToggle`.
- Simulator live: Cheer squad 타일 long press → 메뉴 "다시 듣기에 고정"(재생 요청 없음) → `feedback` 1회 → Home `.home` invalidate로 5요청 재로드 → 타일이 선두로 이동하며 pin 표시 → 서버 `KEEP_OFF`·선두 → 다시 long press → 메뉴가 "다시 듣기에서 고정 해제"(재로드 응답의 새 token) → `feedback` 1회 → 재로드 → 서버 고정 3개로 복귀, 항목별 고정 상태 원 응답과 동일. 가로 paging swipe는 동작 없음, 일반 tap은 `next` 1회(재생) — gesture 충돌 없음.
- replay: 해제 시도 → `notRecorded` → pin 표시 유지 + alert "고정을 해제하지 못했습니다 / 이 요청은 녹화된 응답이 없습니다." 확인.
- Mock: fixture 카드에 서버 toggle 없음 → long press 메뉴 없음, 표시 동일.

#### A8.7 믹스 보관함 저장 / 해제 [확인, 실제 계정 + Simulator live, 원상복구 확인]
- 사전 조사의 `playlistEditEndpoint ACTION_SET_EPHEMERAL_STATUS`는 **이미 보관함에 있는 믹스**(보관 콘텐츠의 몽환적인 믹스)의 header에서만 관찰. 보관함에 없는 믹스(`RDTMAK…`) header toggle은 **재생목록과 같은 `likeEndpoint{LIKE/INDIFFERENT, target.playlistId}`**. `browse/edit_playlist`에 ephemeral 요청을 보내면 HTTP 400 INVALID_ARGUMENT(상태 변화 없음) → 사용하지 않음.
- 앱: 믹스 상세의 기존 `+ / ✓`(`LibrarySaveButton`) 재사용. 변경점: 재생목록 페이지에서 서버 `membership`이 있으면 kind 추정(`isListenersOwn`, 믹스 → 자기 것으로 추정)보다 우선. 같은 interaction grammar(즉시 전환, 실패 시 되돌림 + alert).
- probe(리듬에 몸을 맡기는 밤) + Simulator live(혼란과 소음 사이의 강렬한 에너지, 맞춤 믹스 shelf에서 진입): + 탭 → `like/like` 1회, ✓, 서버 toggle on·보관함 재생목록 3번째·landing 선두 → ✓ 탭 → `like/removelike` 1회, 서버 toggle off, **재생목록 첫 page·landing이 원 응답과 동일**.
- 미확인: 이미 보관함에 있는 믹스(header가 ephemeral endpoint)의 해제 — 앱은 `likeEndpoint` target만 membership으로 읽으므로 그 경우 버튼 없음(보관 믹스를 해제하면 되돌릴 저장 경로가 like인지 확인 필요, 계정 상태 변경을 피하려고 실행 안 함).

#### A8 마무리 계정 상태 확인 (2026-09-29, probe)
- 원 응답과 동일: 보관함 노래 첫 page, 보관함 앨범, 보관함 재생목록, landing, 다시 듣기 항목별 고정 상태, 구독 아티스트.
- 좋아요 목록만 1,111 → 1,112곡: 선두에 散歩の邪魔(`W5LokuZxi0k`) 추가, 기존 100번째가 첫 page 밖으로 밀림. 이 곡은 앱·probe의 어떤 쓰기 로그에도 없고, 06:23(마지막 원복)~08:48 사이 쓰기 없음 → **계정 소유자의 다른 기기 활동으로 판단, 건드리지 않음**. (같은 곡이 보관함 노래에도 선두로 나타난 것과 일치.)
- 실행하지 않은 것: 재생목록 삭제, 관심 없음/추천 안 함, 재생목록 곡 삭제, attestation 우회 구독.

#### 남은 작업 (2026-09-28)
1. (완료) 보관함 검색 → 서버 보관함 탭(A6.7).
1a. (완료) 보관함 고정 판정 → 메뉴 toggle 기준(A6.6). pin/unpin 전후 관찰은 보류.
1b. (완료) 아티스트 보관함/구독 scope(A6.7). 남음: 보관함 아티스트의 MPLA(보관함 곡 목록) 목적지 사용 여부.
2. (완료) Queue domain·`/next` 연결(A7). 남음은 A7 항목 참조.
3. 쓰기 동작 미구현 — A6.5-4 inventory 기준으로 범위 결정 필요(재생목록 삭제·추천 안 함은 비가역).
4. B2 실험(sig/n만 적용 시 200 여부) — 사용자 승인 대기.
5. (완료) A7 checkpoint commit.
6. (완료) A8 Write Actions: 좋아요·앨범/재생목록/믹스 저장·곡 보관함·다시 듣기 고정(A8.1–A8.7). 구독은 (c) 방향으로 미연결.
7. 다음: 앱 내부 인증/session 조사(WKWebView, 공식 web 구독 흐름 검토 포함) → B2 Playback feasibility spike(승인됨, 별도 spike).

### B. Native playback spike (본 앱과 분리)
조사 [가설 — 외부 자료, 이 환경 미검증]:
- yt-dlp PO Token Guide(2026-07-12 편집): `web_music` GVS에 POT 필요, 단 **"GVS PO Token is not required for YouTube Premium subscribers"**. `web_safari` HLS는 **GVS POT 불필요**. → 6절의 HLS segment 403은 POT보다 **n 미변환**이 원인일 가능성이 높아짐(Premium cookie 세션이므로).
- yt-dlp는 sig/n을 regex 추출(JSInterp)에서 **EJS(외부 JS runtime으로 player JS + 유지보수 solver script 실행)**로 전환. player 변경에 solver script를 yt-dlp와 함께 갱신하는 모델.
- YouTubeKit(Swift, 2026-08-18 최신 "fix/youtube-august-26"): player JS에서 함수를 regex로 잘라 **JavaScriptCore**로 n/sig 실행, 깨지면 remote extractor fallback. YouTube 변경마다 수정 릴리스 필요.
- LuanRT/googlevideo: SABR/UMP 프로토콜 JS 구현(protobuf, UMP reader, SABR stream). SABR 경로를 택하면 참고 대상.
- 필수성 분리 실험(제안, 미실행): Premium cookie + WEB_REMIX `signatureCipher` 오디오(itag 141/774) 또는 WEB_SAFARI HLS에 sig/n만 적용 → 200이면 POT/SABR 불필요 확정. 이 실험 자체가 player JS challenge 해결 = 합의된 "우회 구현 전 보고" 경계라 사용자 승인 후 진행.

그 외 미검증: authenticated IOS 계열(cookie 비적용·OAuth 거부), 추가 client, 실제 기기 AVPlayer(재생 가능한 URL 없음).

## 9. 민감정보 / 정리

- `~/.config/itprobe/`의 `browser-headers.itprobe-auth`(전체 로그인 세션), `oauth.itprobe-auth`(refresh token 포함), `oauth-client.env`, `oauth-client.env.save`(client secret)는 저장소 밖 파일이며 실험 후 삭제 권장. GCP OAuth client와 Google 계정의 앱 접근 권한도 해제 가능.
- iPhone의 WebPlayerSpike는 free profile 3개 slot 중 1개를 사용하며 자체 WKWebView 로그인 세션을 갖는다.
- Local tone은 재생성 가능: `ffmpeg -f lavfi -i "sine=frequency=440:beep_factor=4:duration=240:sample_rate=44100" -af volume=0.3 -c:a aac -b:a 96k tone.m4a` 후 `ffmpeg -i tone.m4a -c copy -movflags frag_keyframe+empty_moov+default_base_moof -frag_duration 2000000 tone_frag.mp4`.
