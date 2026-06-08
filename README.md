# br — instant screen brightness toggle for macOS

Instantly black out your Mac's built-in display (0%) and bring it back to 100% —
from the command line or a global hotkey. Because the Mac stays awake at 0%
brightness, a bundled hotkey agent restores the screen **without needing to see a
terminal**.

**English** | [한국어](#한국어)

> Tested on Apple Silicon, macOS 26. Controls the **built-in** display only.
> Uses Apple's private DisplayServices framework and a Carbon global hotkey —
> **no Accessibility permission required**.

---

## English

### Requirements

- macOS on Apple Silicon (built-in display)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`

### Install

```bash
git clone https://github.com/NewTurn2017/screenbrightness.git
cd screenbrightness
make
make install PREFIX=$HOME/.local      # no sudo; or: sudo make install (PREFIX=/usr/local)
```

If you used `PREFIX=$HOME/.local`, make sure it's on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### Usage

| Command     | Action                       |
|-------------|------------------------------|
| `br`        | Toggle 0% ↔ 100%             |
| `br on`     | 100%                         |
| `br off`    | 0%                           |
| `br 80`     | Set 80% (any integer 0–100)  |
| `br status` | Print current percent        |
| `br -h`     | Help                         |

### Global hotkey

```bash
make hotkey-install PREFIX=$HOME/.local
```

This installs a tiny background agent (a launchd LaunchAgent) that starts at login.
By default, **Control-Option-Command-B** toggles 0% ↔ 100% — press it anywhere,
even while the screen is black.

**Configure your own keys** in `~/.config/br/hotkey.conf`, one `action = combo`
per line where `action` is `on`, `off`, or `toggle`:

```conf
on  = cmd+shift+0
off = cmd+shift+9
```

Or a single toggle key:

```conf
toggle = ctrl+opt+cmd+b
```

(A bare line with no `=`, like `ctrl+opt+cmd+b`, is treated as a toggle.)

**Combo syntax** — separators `+`, `-`, or space; modifiers `ctrl`, `opt`/`alt`,
`cmd`, `shift`; keys `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `escape`, `return`,
`tab`. Lines starting with `#` are ignored.

After editing the config, reload: `make hotkey-install PREFIX=$HOME/.local`.

Agent logs: `~/Library/Logs/br-agent.log`. If you pick a combo macOS already owns
(e.g. `cmd+space`), the agent logs a "could not register" line and your other keys
still work.

### Uninstall

```bash
make hotkey-uninstall PREFIX=$HOME/.local   # remove the hotkey agent
make uninstall PREFIX=$HOME/.local          # remove the binary
```

### How it works

- **Built-in display:** found by enumerating displays and picking the one where
  `CGDisplayIsBuiltin` is true (not `CGMainDisplayID`, which can point at a virtual
  display).
- **Brightness:** Apple's private `DisplayServices` framework
  (`DisplayServicesGetBrightness` / `SetBrightness`), loaded at runtime via
  `dlopen`/`dlsym`.
- **Hotkey:** Carbon `RegisterEventHotKey` in a headless `NSApplication` accessory
  run loop — needs **no Accessibility permission** (unlike event taps).

### Caveats

- macOS auto-brightness (ambient light sensor) may slowly raise brightness after
  `br off`. Turn it off in System Settings → Displays if that bothers you.
- Apple panels keep a faint glow at 0% (not pure black) — expected.
- Installing to `/usr/local/bin` may need `sudo`; `$HOME/.local/bin` avoids it.

### Develop

```bash
make test     # non-destructive: unit tests + a brightness get/set round-trip
make clean
```

### License

MIT — see [LICENSE](LICENSE).

---

## 한국어

맥 내장 디스플레이를 **즉시 끄고(0%) 다시 100%로** 켜는 macOS CLI 도구입니다.
명령어로도, 전역 단축키로도 쓸 수 있습니다. 화면 밝기가 0%여도 맥은 깨어 있기
때문에, 함께 설치되는 단축키 에이전트가 **터미널을 보지 않고도** 화면을 다시
켜 줍니다.

> Apple Silicon, macOS 26에서 테스트했습니다. **내장 디스플레이 전용**입니다.
> Apple의 비공개 DisplayServices 프레임워크와 Carbon 전역 단축키를 사용하며,
> **손쉬운 사용(Accessibility) 권한이 필요 없습니다.**

### 요구 사항

- Apple Silicon 맥 (내장 디스플레이)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`

### 설치

```bash
git clone https://github.com/NewTurn2017/screenbrightness.git
cd screenbrightness
make
make install PREFIX=$HOME/.local      # sudo 불필요. 또는: sudo make install (PREFIX=/usr/local)
```

`PREFIX=$HOME/.local`로 설치했다면 `PATH`에 추가하세요:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### 사용법

| 명령어      | 동작                          |
|-------------|-------------------------------|
| `br`        | 0% ↔ 100% 토글                |
| `br on`     | 100%                          |
| `br off`    | 0%                            |
| `br 80`     | 80%로 설정 (0–100 정수)       |
| `br status` | 현재 밝기(%) 출력             |
| `br -h`     | 도움말                        |

### 전역 단축키

```bash
make hotkey-install PREFIX=$HOME/.local
```

로그인 시 자동 실행되는 작은 백그라운드 에이전트(launchd LaunchAgent)를
설치합니다. 기본값은 **Control-Option-Command-B**로 0% ↔ 100% 토글이며, 화면이
꺼진 상태에서도 어디서나 누를 수 있습니다.

**원하는 키로 바꾸기** — `~/.config/br/hotkey.conf`에 한 줄에 `동작 = 조합`
형식으로 적습니다. `동작`은 `on`, `off`, `toggle` 중 하나입니다:

```conf
on  = cmd+shift+0
off = cmd+shift+9
```

또는 토글 키 하나만:

```conf
toggle = ctrl+opt+cmd+b
```

(`=`가 없는 한 줄(`ctrl+opt+cmd+b` 등)은 토글로 처리됩니다.)

**조합 문법** — 구분자 `+`, `-`, 공백 / 수정자 `ctrl`, `opt`(=`alt`), `cmd`,
`shift` / 키 `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `escape`, `return`, `tab`.
`#`로 시작하는 줄은 무시됩니다.

설정을 바꾼 뒤에는 다시 적용하세요: `make hotkey-install PREFIX=$HOME/.local`.

에이전트 로그: `~/Library/Logs/br-agent.log`. macOS가 이미 쓰는 조합(예:
`cmd+space`)을 고르면 "could not register" 로그가 남고 나머지 키는 정상 동작합니다.

### 제거

```bash
make hotkey-uninstall PREFIX=$HOME/.local   # 단축키 에이전트 제거
make uninstall PREFIX=$HOME/.local          # 실행 파일 제거
```

### 동작 원리

- **내장 디스플레이:** 모든 디스플레이를 열거한 뒤 `CGDisplayIsBuiltin`이 참인
  것을 고릅니다(가상 디스플레이를 가리킬 수 있는 `CGMainDisplayID` 대신).
- **밝기 제어:** Apple의 비공개 `DisplayServices` 프레임워크
  (`DisplayServicesGetBrightness` / `SetBrightness`)를 `dlopen`/`dlsym`으로
  런타임에 로드합니다.
- **단축키:** 헤드리스 `NSApplication`(accessory) 런루프 안에서 Carbon
  `RegisterEventHotKey`를 사용합니다. 이벤트 탭과 달리 **손쉬운 사용 권한이
  필요 없습니다.**

### 참고 사항

- 자동 밝기(주변광 센서)가 `br off` 후 밝기를 서서히 올릴 수 있습니다. 거슬리면
  시스템 설정 → 디스플레이에서 끄세요.
- Apple 패널은 0%에서도 미세한 빛이 남습니다(완전한 검정 아님) — 정상입니다.
- `/usr/local/bin` 설치에는 `sudo`가 필요할 수 있고, `$HOME/.local/bin`은 필요
  없습니다.

### 개발

```bash
make test     # 비파괴 테스트: 단위 테스트 + 밝기 get/set 왕복 검증
make clean
```

### 라이선스

MIT — [LICENSE](LICENSE) 참고.
