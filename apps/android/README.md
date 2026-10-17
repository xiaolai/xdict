# android

Android, in Kotlin and Jetpack Compose. Lookups start from the text-selection menu of any app
(`ACTION_PROCESS_TEXT`); files come through the Storage Access Framework. Not started.

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in, once the Gradle module exists:

- `android { sourceSets { main { res.srcDirs += "<path to>/apps/android/icons/res" } } }`
- the manifest: `android:icon="@mipmap/ic_launcher"` and `android:roundIcon="@mipmap/ic_launcher_round"`. These are
  adaptive on API 26 and later, with a monochrome layer for themed icons on 33 and later; legacy PNGs below 26
- a notification: `setSmallIcon(R.drawable.ic_stat_xdict)` (white on alpha)
- the Play Store listing: `icons/play-store-512.png`
