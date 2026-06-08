# Vigil

**Keep your Mac awake — and never let it lock on you.** A tiny native macOS CLI +
global hotkeys that keep the system *and* display from sleeping on macOS's own idle
timer (the thing that locks your screen), so long-running work (AI agents, builds,
downloads, servers) never gets interrupted. The screen still goes dark on *your*
terms — instantly via `away`, or automatically after a configurable idle —
**with no lock and no password.** Plus instant brightness control and an immediate
sleep when you actually want it. No third-party apps, **no Accessibility
permission, and no runtime password prompts.**

**English** | [한국어](#한국어)

> Tested on Apple Silicon, macOS 26. Brightness controls the built-in display;
> `away` blacks out **all** displays (external monitors via a black overlay).
> Uses Apple's private DisplayServices framework, Carbon global hotkeys, AppKit,
> and `caffeinate`/`pmset` — all root-free at runtime.

---

## English

### Why Vigil

Tools like Amphetamine keep your Mac awake — but macOS still blanks the display on
its idle timer, and waking it wants your password. Vigil keeps the *system and
display* awake so macOS never turns the screen off or locks it on its own. The
display only goes dark the way *you* choose — and it never asks for a password:

| Mode | What it does |
|------|--------------|
| **work** ☀️ | Keep awake + screen **on** (100%). macOS never idle-offs or locks the display. |
| **away** 🌙 | Keep awake + **all displays black now** (built-in dims to 0, externals get a black overlay — **no lock, no password**; press `work` to bring it back). |
| **auto-away** 🌑 | After a configurable idle (default **10 min**), `away` fires by itself — dark, still no lock. Wake with `work`. |
| **sleep** 💤 | Stop keeping awake + **sleep the Mac now** (this one *does* sleep & lock — on purpose). |

`work` / `away` / `auto-away` keep the system awake (the Amphetamine replacement);
`sleep` is the only thing that actually sleeps the Mac.

### Requirements

- Apple Silicon Mac (built-in display)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`

### Install

```bash
git clone https://github.com/NewTurn2017/vigil.git
cd vigil
make
make install PREFIX=$HOME/.local      # no sudo; or: sudo make install (PREFIX=/usr/local)
```

Ensure your install bin is on `PATH` (for `$HOME/.local`):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### Usage

```
power modes:
  vigil work       keep awake + screen on (100%)
  vigil away       keep awake + screen off now
  vigil sleep      sleep the Mac now
  vigil awake on   keep awake only
  vigil awake off  stop keeping awake
  vigil awake status

brightness:
  vigil            toggle 0% <-> 100%
  vigil on/off     100% / 0%
  vigil 80         set 80% (any integer 0-100)
  vigil status     print current percent
```

### Global hotkeys

```bash
make hotkey-install PREFIX=$HOME/.local
```

This installs a background agent (launchd) that starts at login and registers your
hotkeys. Configure them in `~/.config/vigil/hotkey.conf`, one `action = combo` per
line. Recommended:

```conf
work  = ctrl+opt+cmd+0
away  = ctrl+opt+cmd+9
sleep = ctrl+opt+cmd+8
autoaway = 10m            # auto-fire `away` after this much idle (90s / off / etc.)
```

So **⌃⌥⌘0** = work, **⌃⌥⌘9** = away, **⌃⌥⌘8** = sleep (descending 0→9→8 = "more
awake → less awake → asleep").

`autoaway` is a setting, not a hotkey: the agent watches keyboard/mouse idle and
fires `away` once it passes the threshold (`10m`, `90s`, bare seconds, or `off` to
disable; default `10m`). It re-arms after you press `work`. Note it tracks raw
input idle, so a video with no keypresses will still go dark after the threshold.

Actions: `work`, `away`, `sleep`, `on`, `off`, `toggle`. Modifiers: `ctrl`,
`opt`/`alt`, `cmd`, `shift`. Keys: `a`–`z`, `0`–`9`, `f1`–`f20`, `space`,
`escape`, `return`, `tab`. Separators `+`, `-`, or space. After editing, reload
with `make hotkey-install PREFIX=$HOME/.local`. Agent logs:
`~/Library/Logs/vigil-agent.log`.

> **Avoid combos other apps grab.** Launchers like Alfred/Raycast can eat
> `cmd+shift+<number>`; the `⌃⌥⌘` ("hyper") combos above are conflict-free. If a
> bound key never fires, pick a different combo. Note `⌃⌥⌘8` may toggle macOS
> "Invert colors" if that accessibility shortcut is enabled — disable it or choose
> another key for `sleep`.

### Clamshell mode (optional)

`vigil off` can also disable system sleep so you can close the lid and keep running
(clamshell), and `vigil on` restores normal sleep. This is the one feature that
needs a one-time, tightly-scoped sudo rule (passwordless `pmset` for *only* the two
clamshell commands):

```bash
make sleep-setup      # installs /etc/sudoers.d/vigil (asks your password once)
```

After setup, `vigil off` → `pmset disablesleep 1`, `vigil on` → `disablesleep 0`.
Remove with `make sleep-teardown`. Without it, brightness still works and nothing
touches sleep.

### Passwords

Vigil **never prompts for a password at runtime.** Keeping awake, preventing
display sleep, brightness, and force-sleep are all root-free; clamshell uses
passwordless `sudo -n`. The only password you'll see is macOS unlocking after an
explicit `sleep` (and the one-time `make sleep-setup`).

### Uninstall

```bash
make sleep-teardown                         # remove the clamshell sudo rule
make hotkey-uninstall PREFIX=$HOME/.local   # remove the agent + keep-awake job
make uninstall PREFIX=$HOME/.local          # remove the binary
```

### How it works

- **Keep awake:** a launchd-managed `caffeinate -i` job (prevents idle *system*
  sleep) **plus** a continuous `PreventUserIdleDisplaySleep` power assertion held by
  the agent for its whole life — this stops the OS *display*-sleep timer that would
  otherwise blank and lock the screen. Session-scoped — a reboot returns to normal.
- **Auto-away:** the agent polls input idle time (IOHIDSystem `HIDIdleTime`) and
  fires `away` once it passes the configured threshold (`autoaway`); pressing `work`
  re-arms it.
- **Brightness:** Apple's private `DisplayServices` framework, loaded via
  `dlopen`/`dlsym`; the built-in display is found via `CGDisplayIsBuiltin`.
- **Screen off (away):** the built-in dims to brightness 0; each external monitor
  gets an opaque black overlay window (held by the agent), since DisplayServices
  can't dim externals. No display *sleep* → macOS never locks (no password). The
  CLI signals the agent via a Darwin notification so `vigil away` and the hotkey
  behave identically. **Sleep:** `pmset sleepnow`.
- **Hotkeys:** Carbon `RegisterEventHotKey` in a headless `NSApplication` — **no
  Accessibility permission**.

### Develop

```bash
make test     # non-destructive: unit tests + a brightness get/set round-trip
make clean
```

### License

MIT — see [LICENSE](LICENSE).

---

## 한국어

**맥은 깨워두고 — 잠기지 않게.** AI 에이전트·빌드·다운로드·서버처럼 오래 도는
작업이 **중단되지 않도록**, 시스템과 화면을 macOS 자체 유휴 타이머(화면을
잠그는 그것)로부터 안 재우는 작은 네이티브 macOS CLI + 전역 단축키 도구입니다.
화면은 **원할 때만** 어두워집니다 — `away`로 즉시, 또는 설정한 유휴 시간 뒤
자동으로 — **잠금도 비밀번호도 없이.** 즉시 밝기 제어와, 원할 때 바로
재우기까지. 서드파티 앱 없음, **손쉬운 사용 권한 불필요, 런타임 비밀번호
프롬프트 없음.**

> Apple Silicon, macOS 26에서 테스트. 밝기는 내장 디스플레이 제어, `away`는
> **모든 디스플레이**를 검게(외부 모니터는 검은 오버레이). 비공개 DisplayServices,
> Carbon 전역 단축키, AppKit, `caffeinate`/`pmset` 사용 — 런타임 root 불필요.

### 왜 Vigil인가

Amphetamine 같은 도구는 맥을 깨워두지만, macOS는 여전히 유휴 타이머로 화면을 끄고
깨울 때 비밀번호를 묻습니다. Vigil은 *시스템과 화면*을 깨워둬서 macOS가 스스로
화면을 끄거나 잠그지 못하게 합니다. 화면은 오직 원하는 방식으로만 어두워지고,
비밀번호도 묻지 않습니다:

| 모드 | 동작 |
|------|------|
| **work** ☀️ | 깨어있기 + 화면 **켜기**(100%). macOS가 화면을 멋대로 끄거나 잠그지 않음 |
| **away** 🌙 | 깨어있기 + **모든 디스플레이 즉시 검게**(내장은 밝기 0, 외부는 검은 오버레이 — **잠금·비밀번호 없음**; `work`로 다시 켬) |
| **auto-away** 🌑 | 설정한 유휴 시간(기본 **10분**) 뒤 `away`가 자동 발동 — 어둡지만 잠금 없음. `work`로 깨움 |
| **sleep** 💤 | 깨어있기 해제 + **지금 바로 재우기**(이것만 실제로 자고 잠김 — 의도된 동작) |

`work`/`away`/`auto-away`는 시스템을 깨워둠(= Amphetamine 대체), `sleep`만 실제로 맥을 재움.

### 요구 사항

- Apple Silicon 맥 (내장 디스플레이)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`

### 설치

```bash
git clone https://github.com/NewTurn2017/vigil.git
cd vigil
make
make install PREFIX=$HOME/.local      # sudo 불필요. 또는: sudo make install (PREFIX=/usr/local)
```

`PREFIX=$HOME/.local`이면 `PATH`에 추가:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### 사용법

```
전원 모드:
  vigil work       깨어있기 + 화면 켜기(100%)
  vigil away       깨어있기 + 화면 즉시 끄기
  vigil sleep      지금 재우기
  vigil awake on   깨어있기만 켜기
  vigil awake off  깨어있기 끄기
  vigil awake status

밝기:
  vigil            0% <-> 100% 토글
  vigil on/off     100% / 0%
  vigil 80         80%로 설정 (0-100 정수)
  vigil status     현재 밝기(%) 출력
```

### 전역 단축키

```bash
make hotkey-install PREFIX=$HOME/.local
```

로그인 시 자동 실행되는 백그라운드 에이전트(launchd)가 단축키를 등록합니다.
`~/.config/vigil/hotkey.conf`에 한 줄에 `동작 = 조합` 형식으로 설정. 추천:

```conf
work  = ctrl+opt+cmd+0
away  = ctrl+opt+cmd+9
sleep = ctrl+opt+cmd+8
autoaway = 10m            # 이만큼 유휴면 away 자동 발동 (90s / off 등)
```

즉 **⌃⌥⌘0** = work, **⌃⌥⌘9** = away, **⌃⌥⌘8** = sleep (0→9→8 내림차순 = "더
깨어있음 → 덜 깨어있음 → 잠").

`autoaway`는 단축키가 아니라 설정값입니다: 에이전트가 키보드/마우스 유휴 시간을
보다가 임계값을 넘으면 `away`를 발동합니다(`10m`, `90s`, 초 단위 숫자, 끄려면
`off`; 기본 `10m`). `work`를 누르면 다시 무장됩니다. 입력 유휴만 보므로, 키 입력
없는 영상도 임계값이 지나면 검게 됩니다.

동작: `work`, `away`, `sleep`, `on`, `off`, `toggle`. 수정자: `ctrl`, `opt`(=`alt`),
`cmd`, `shift`. 키: `a`–`z`, `0`–`9`, `f1`–`f20`, `space` 등. 구분자 `+`, `-`, 공백.
수정 후 `make hotkey-install PREFIX=$HOME/.local`로 다시 적용. 로그:
`~/Library/Logs/vigil-agent.log`.

> **다른 앱이 가로채는 조합 피하기.** Alfred/Raycast 같은 런처가
> `cmd+shift+숫자`를 먹을 수 있어요. 위의 `⌃⌥⌘`(하이퍼) 조합은 충돌이 없습니다.
> 단축키가 안 먹으면 다른 조합으로 바꾸세요. `⌃⌥⌘8`은 macOS "색상 반전"
> 접근성 단축키와 겹칠 수 있으니, 켜져 있으면 끄거나 `sleep` 키를 바꾸세요.

### 클램쉘 모드 (선택)

`vigil off`는 시스템 잠들기까지 꺼서 덮개를 닫고도 돌릴 수 있고(클램쉘),
`vigil on`이 정상 복귀합니다. 이 기능만 일회성의 아주 좁은 sudo 규칙(딱 두
`pmset` 명령만 비밀번호 없이)이 필요합니다:

```bash
make sleep-setup      # /etc/sudoers.d/vigil 설치 (비밀번호 1회)
```

설치 후 `vigil off` → `pmset disablesleep 1`, `vigil on` → `disablesleep 0`.
제거는 `make sleep-teardown`. 설치 안 해도 밝기는 그대로 동작하고 잠들기는 안 건드림.

### 비밀번호

Vigil은 **런타임에 비밀번호를 절대 묻지 않습니다.** 깨어있기·디스플레이 슬립
방지·밝기·강제 재우기 전부 root 불필요, 클램쉘은 비대화형 `sudo -n`. 비밀번호는
오직 **명시적 `sleep`으로 재운 뒤 macOS 잠금 해제**(그리고 일회성
`make sleep-setup`) 뿐입니다.

### 제거

```bash
make sleep-teardown                         # 클램쉘 sudo 규칙 제거
make hotkey-uninstall PREFIX=$HOME/.local   # 에이전트 + 깨어있기 잡 제거
make uninstall PREFIX=$HOME/.local          # 실행 파일 제거
```

### 동작 원리

- **깨어있기:** launchd가 관리하는 `caffeinate -i` 잡(시스템 idle sleep 방지)에
  **더해**, 에이전트가 살아있는 내내 `PreventUserIdleDisplaySleep` 전원 어설션을
  상시 유지 — 화면을 끄고 잠가버리는 OS *디스플레이* 슬립 타이머를 막습니다.
  세션 한정 — 재부팅하면 정상 복귀.
- **auto-away:** 에이전트가 입력 유휴 시간(IOHIDSystem `HIDIdleTime`)을 폴링하다
  설정 임계값(`autoaway`)을 넘으면 `away`를 발동; `work`를 누르면 다시 무장.
- **밝기:** 비공개 `DisplayServices`를 `dlopen`/`dlsym`으로 로드; 내장
  디스플레이는 `CGDisplayIsBuiltin`으로 찾음.
- **화면 끄기(away):** 내장은 밝기 0, 외부 모니터는 불투명 검은 오버레이 창(에이전트가
  띄움 — DisplayServices가 외부는 못 끄므로). 디스플레이 *슬립*이 아니라 잠금/비밀번호
  없음. CLI는 Darwin 알림으로 에이전트에 신호를 보내 `vigil away`와 단축키가 동일하게
  동작. **재우기:** `pmset sleepnow`.
- **단축키:** 헤드리스 `NSApplication`에서 Carbon `RegisterEventHotKey` — **손쉬운
  사용 권한 불필요**.

### 개발

```bash
make test     # 비파괴: 단위 테스트 + 밝기 get/set 왕복
make clean
```

### 라이선스

MIT — [LICENSE](LICENSE) 참고.
