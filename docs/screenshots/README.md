# Screenshots

The `.svg` files here are **placeholders**. They have the size and name of the picture that will replace them. None
of them is a capture of the app.

The real pictures are made by the in-app screen walk (`ScreenWalkTests`) and saved to the git-ignored
`.logs/shots/`, as `App/STATUS.md` explains. To replace a placeholder, copy the matching PNG here, check that it shows
only synthetic demo notes, and change the `.svg` link in the top-level `README.md` to `.png`.

| Placeholder | Screen | Launch arguments (demo mode, no GitHub) |
|---|---|---|
| `phone-folders-light.svg` | Folders home | `-BNScreen folders -BNPhoneLayout` |
| `phone-note-light.svg` | Rendered note | `-BNScreen note -BNPhoneLayout` |
| `phone-edit-hebrew.svg` | Editor, Hebrew right to left | `-BNScreen edit -BNPhoneLayout -BNHebrew` |
| `phone-conflict-light.svg` | A conflict copy in the Inbox | `-BNScreen conflict -BNPhoneLayout` |
| `phone-welcome-dark.svg` | Onboarding: Welcome | `-BNScreen welcome -BNPhoneLayout` |
| `mac-attention-light.svg` | Needs attention, both versions side by side | `-BNScreen attention` |

Rules for anything added here:

- Demo content only. Demo mode loads the synthetic notes in `Fixtures/demo-brain/` onto the in-process fake GitHub.
  Never capture a real brain.
- No GitHub account names, device codes, tokens or client IDs. The `code` screen in demo mode shows a fake code; keep
  it that way.
- `-BNPhoneLayout` is the iPhone's navigation in a phone-sized Mac window. It is not iPhone rendering. Label a picture
  "iPhone" only if it came from a device or simulator.
