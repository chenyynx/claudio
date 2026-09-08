# Claude 인증 문제 해결

CC Pocket은 Bridge 컴퓨터에 저장된 Claude Code 로그인 상태를 사용합니다.
인증에 실패하면 해당 컴퓨터에서 Claude Code에 다시 로그인하세요.

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
