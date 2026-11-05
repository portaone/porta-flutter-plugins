# Contributing

## Setup

1. Flutter 3.35 or newer (Dart 3.9), stable channel.
2. Clone the repository and resolve the whole workspace from its root:

   ```sh
   flutter pub get
   ```

   One `flutter pub get` at the root resolves every package and example listed under `workspace:` in the root `pubspec.yaml`, with one shared lockfile. Do not run it inside a package first: a member has no lockfile of its own.
3. Run the checks before a pull request:

   ```sh
   dart run melos analyze
   dart run melos format
   dart run melos test
   ```

   A package may have checks of its own (native tests, device tests); its README lists them.

## Commit convention

[Conventional Commits](https://www.conventionalcommits.org), with the package's name as the scope:

```
feat(flutter_webrtc_noise_suppression): add a suppression level
fix(flutter_webrtc_noise_suppression): guard the engine check in the registry
docs(flutter_webrtc_noise_suppression): document the capture path
```

A change to the repository itself, not to a package, takes no scope or the scope `repo`: `ci(repo): pin the Flutter action`. Types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`. The subject is lower case, without a full stop, and names what changed. One pull request changes one package.

## Pull requests

- Every change to a package that users will see adds a line under `## Unreleased` in that package's `CHANGELOG.md`.
- CI runs the shared checks (analyze, format, tests, a publish dry run) and the package's own jobs; it must be green before merging.
- Pull requests are merged by rebase, so the commits land on `main` as they are.

## Releases

Each package is released on its own, from `main`, by a tag:

1. In a pull request, set `version:` in the package's `pubspec.yaml` and turn `## Unreleased` in its `CHANGELOG.md` into `## <version>`.
2. After it is merged, tag that commit and push the tag:

   ```sh
   git tag <package>-v<version>      # e.g. flutter_webrtc_noise_suppression-v0.1.0
   git push origin <package>-v<version>
   ```

3. The package's publish workflow runs on the tag and publishes it to pub.dev through GitHub's OIDC token (no secret is stored here), in the GitHub environment `pub.dev`.

The first version of a new package is published by hand: pub.dev allows automated publishing only for a package that already exists. See "Adding a new package".

## Adding a new package

Described step by step in a later revision of this file.
