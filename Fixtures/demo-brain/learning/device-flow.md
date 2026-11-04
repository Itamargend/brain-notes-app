# OAuth device flow
App asks for a code → user types it at github.com/login/device → app polls for the token.
No client secret on the device. Store tokens in the Keychain only.
