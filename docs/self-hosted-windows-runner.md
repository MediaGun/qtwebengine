# Preparing a self-hosted Windows runner for the Qt WebEngine build

What a self-hosted Windows machine needs to run the "Build for Windows" job of `.github/workflows/build.yaml`: Qt WebEngine and Qt Pdf 6.140.0 for Qt 6.12.0.

Sources:
- the GitHub-hosted `windows-2022` image, which the job uses today ([Windows2022-Readme.md](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md), image 20261101.353.1);
- Qt's requirements for building Qt WebEngine from source ([Qt WebEngine Platform Notes](https://doc.qt.io/qt-6/qtwebengine-platform-notes.html)).

Written 2026-11-09.

## Software to install on the machine

The hosted image has these, and the job expects them.

| Software | On the hosted image | Why / minimum |
|---|---|---|
| Windows Server 2022, or Windows 10/11, 64-bit | Server 2022 | |
| **Visual Studio 2022** (Build Tools are enough) with **Desktop development with C++**: `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` and `Microsoft.VisualStudio.Component.VC.ATL` | 17.14, MSVC 14.44 | Qt WebEngine needs MSVC **14.36 or newer**. Chromium uses ATL. `ilammy/msvc-dev-cmd` finds Visual Studio through `vswhere`, which Visual Studio installs. |
| **Windows 11 SDK 10.0.26100**, with **Debugging Tools for Windows** | 10.0.26100.0 | Qt WebEngine 6.140 needs **10.0.26100 or newer**. Chromium's build also uses the SDK's debugging tools. |
| **Git** | 2.56 | The job clones the sources, with `core.longpaths true`. |
| **PowerShell 7** (`pwsh`) | yes | The "Prepare environment" step runs in `pwsh`. |
| **Perl** | Strawberry Perl 5.32 | The job runs `perl -v` and fails without it. |
| **Chocolatey** | 2.7 | The job installs `gperf` and `winflexbison3` with it on every run. |
| **gperf**, **winflexbison3** (bison and flex) | installed by the job | Qt WebEngine needs them. Installing them once saves a step on every run. |
| **Python 3.12** with `pip` | 3.12.10 | aqtinstall (which installs Qt), Chromium's build scripts, and `html5lib` need it. Installing it saves a download on every run. |

With Visual Studio Installer, the two components above can be added from the command line:

```
vs_buildtools.exe --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.ATL --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended --passive --norestart
```

The Debugging Tools for Windows come with the Windows SDK installer (feature "Debugging Tools for Windows"). They aren't a Visual Studio component.

## Downloaded by the job

Nothing to install here: the job's actions fetch these on every run. The machine only needs internet access.

| Tool | Action | Minimum |
|---|---|---|
| Node.js 20 | `actions/setup-node` | 20 |
| CMake 3.31.6 | `jwlawson/actions-setup-cmake` | 3.25 for Qt 6.12 |
| Ninja | `seanmiddleditch/gha-setup-ninja` | |
| Qt 6.12.0 `msvc2022_64` with Qt Shader Tools | `jurplel/install-qt-action`, through aqtinstall | |
| sccache | `hendrikmuhs/ccache-action` | |
| `html5lib` | `pip install` in the job | |

The hosted image has many other tools (Go, Java, the Android SDK, databases, browsers, …) that this build doesn't use.

## The machine

- **Disk:** about **150 GB free on an SSD**, for the Chromium sources, the build, the sccache cache and Qt.
- **CPU and RAM:** as many cores as possible, and **at least 32 GB RAM**; 64 GB is better. Linking Chromium's large libraries needs a lot of memory.
- **Internet access:** github.com, download.qt.io (Qt and aqtinstall), chocolatey.org, nodejs.org and PyPI.
- **Long paths:** turn on `LongPathsEnabled` once, as an administrator:

  ```
  Set-ItemProperty HKLM:\System\CurrentControlSet\Control\Filesystem LongPathsEnabled 1
  ```

- **The runner:** install the GitHub Actions runner as a service, with the label `windows-we-builder`, which the job's `runs-on` asks for ([adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)).

## Changes to the workflow for a self-hosted runner

- **Runner label:** done: the job runs on `[ self-hosted, windows-we-builder ]`.
- **`D:\` paths:** the job builds in `D:\qtwe\…`, a drive that hosted runners have. Either the machine has a `D:` drive with enough space, or the paths change.
- **Admin rights:** "Prepare environment" sets `LongPathsEnabled` in the registry, which needs admin rights. With long paths turned on once (above), that line can go, and the runner service doesn't need to run as an administrator.
- **Time limits:** jobs on self-hosted runners can run for up to 5 days. The job's 360-minute limit and the build step's 300-minute limit can be raised or dropped.
- **Cache:** with a disk that persists between runs, sccache can keep its cache locally (`SCCACHE_DIR`). That drops the 10 GB limit of GitHub's cache, and the problem that a tag build can't use the cache saved on a branch.
- **Pre-installed tools:** with gperf, winflexbison3 and Python installed once, the `choco install` step and `actions/setup-python` can go.
