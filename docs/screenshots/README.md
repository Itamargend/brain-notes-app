# Screenshots

The `.png` files here are captured by the in-app screen walk (`ScreenWalkTests`) against the synthetic demo session
(`Fixtures/demo-brain/`, in-process fake GitHub, no real account or repository).

| File | Screen | Launch arguments (demo mode, no GitHub) |
|---|---|---|
| `phone-folders-light.png` | Folders home | `-BNScreen folders -BNPhoneLayout` |
| `phone-note-light.png` | Rendered note | `-BNScreen note -BNPhoneLayout` |
| `phone-edit-hebrew.png` | Editor, Hebrew right to left | `-BNScreen edit -BNPhoneLayout -BNHebrew` |
| `phone-conflict-light.png` | Side-by-side conflict comparison | `-BNScreen conflict -BNPhoneLayout` |
| `phone-welcome-dark.png` | Onboarding: Welcome | `-BNScreen welcome -BNPhoneLayout` |
| `mac-attention-light.png` | Needs attention, both versions side by side | `-BNScreen attention` |

Rules for anything added here:

- Demo content only. Demo mode loads the synthetic notes in `Fixtures/demo-brain/` onto the in-process fake GitHub.
  Never capture a real brain.
- No GitHub account names, device codes, tokens or client IDs. In demo mode the `code` screen can't start a real
  device flow; never capture it from a live sign-in.
- `-BNPhoneLayout` is the iPhone's navigation in a phone-sized Mac window. It is not iPhone rendering. Label a picture
  "iPhone" only if it came from a device or simulator.
