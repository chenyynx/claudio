# Claude 인증 문제 해결

[English](auth-troubleshooting.md) | [日本語版](auth-troubleshooting.ja.md) | [简体中文版](auth-troubleshooting.zh-CN.md)

CC Pocket은 기본적으로 `ANTHROPIC_API_KEY`를 사용합니다. 구독 인증은 Bridge 관리자가
`BRIDGE_ALLOW_CLAUDE_OAUTH=1`을 명시적으로 설정하고 Bridge를 다시 시작한 경우에만
활성화됩니다.

## 구독 인증에 명시적 활성화가 필요한 이유

Anthropic의 [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
페이지에는 명시된 조건을 충족할 경우 Commercial Terms가 플랫폼의 수정되지 않은 Claude Code
호스팅과 각 최종 사용자의 자체 구독 또는 기타 자격 증명 로그인을 막지 않는다는 내용이 있습니다.
CC Pocket도 사용자의 Bridge 컴퓨터에서 공식 Claude Agent SDK를 실행하고 인증을 호스트의
Claude Code 환경에 위임합니다. CC Pocket 자체는 Claude OAuth 인증 정보를 복사, 저장 또는
갱신하지 않습니다.

사용자의 컴퓨터에서 Claude Code를 실행하고 원격으로 제어하는 방식은
[OpenClaw](https://github.com/openclaw/openclaw/blob/main/docs/concepts/oauth.md),
[Happy](https://github.com/slopus/happy), [Termopus](https://github.com/Termopus/termopus)
같은 유사 도구에서도 사용되지만 구체적인 구현은 서로 다릅니다.

반면 Anthropic의 [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk)는
사전 승인을 받지 않은 타사 제품에 Claude.ai 로그인이나 구독 한도를 제공하지 말고 API 키를
사용하도록 안내합니다. 이 설명들이 CC Pocket 구조에 어떻게 적용되는지는 명확하지 않으며,
Anthropic이 향후 이 인증 방식을 제한할 수 있습니다.

이 불확실성을 피하려면 `ANTHROPIC_API_KEY`를 설정하세요. 위험을 이해하고 구독 인증을
선택한다면 다음과 같이 Bridge를 실행하세요.

```bash
BRIDGE_ALLOW_CLAUDE_OAUTH=1 npx @ccpocket/bridge@latest
```

활성화 후 구독 인증에 실패하면 Bridge 컴퓨터에서 Claude Code에 다시 로그인하고 Bridge를
다시 시작하세요.

## Bridge 컴퓨터를 직접 사용할 수 없을 때

CC Pocket을 사용할 때 Bridge 컴퓨터는 집에서 실행 중인 Mac mini나 다른 Mac일 수 있습니다.
이 경우에도 휴대폰에서 원격으로 Claude Code에 다시 로그인할 수 있습니다.

1. 터미널 앱에서 Bridge 컴퓨터에 연결
   - Mosh, Termius, Blink 또는 다른 SSH 클라이언트를 사용할 수 있습니다
2. `claude` 실행
3. Claude Code 안에서 `/login` 실행
4. 표시된 URL을 휴대폰이나 PC 브라우저에서 열기
5. 브라우저에서 로그인을 완료
6. 터미널에서 붙여넣기를 요청하면 브라우저에 표시된 결과를 다시 붙여넣기

다음 요청부터 CC Pocket이 업데이트된 로그인 상태를 사용합니다.

## Bridge 컴퓨터를 직접 사용할 수 있을 때

1. Bridge 컴퓨터에서 `claude` 실행
2. `/login` 실행
3. 브라우저에서 로그인 절차 완료

## 셸 명령 대안

원한다면 다음 명령도 사용할 수 있습니다.

```bash
claude auth login
```

## 발생하는 원인

- Claude 로그인이 만료됨
- Claude Code 업데이트 후 이전 로그인 상태가 무효화됨
- Anthropic이 저장된 토큰을 취소함
