# AMProjShareExtension

Experimental iOS Share Extension for passing one `.amproj` file from QQ or
Files to the injected Alight Motion app.

## Build

Requires macOS and the iPhoneOS SDK from Xcode:

```sh
make
```

Outputs:

- `build/AMProjShareExtension.appex`
- `build/AMProjShareExtension.entitlements`

The `.appex` is unsigned. Embed it at
`Payload/<App>.app/PlugIns/AMProjShareExtension.appex`, then sign the extension
before signing the containing app.

Both the containing app and extension must be signed with this App Group:

```text
group.com.amayaka.meow.amprojshare
```

The extension writes completed requests under:

```text
AMProjShareInbox/<request UUID>/
  payload.amproj
  request.plist
```

`request.plist` is written last, so the containing app can use it as the commit
marker. The extension then requests this URL:

```text
alightmotion://amproj-import?request=<request UUID>
```

Some free/self-signing profiles do not permit custom App Groups. In that case
the extension shows an App Group error and cannot exchange files with the main
app. Some iOS versions also reject `NSExtensionContext.openURL` for Share
Extensions; the request remains queued so the main app can scan it on its next
activation.
