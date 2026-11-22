# cs2-pc-tuning

Scripturi PowerShell pentru setările de CS2 pe PC-ul meu: profilul NVIDIA, salvarea și restaurarea unei stări bune, migrarea setărilor după un update de driver.

> Scripturile sunt făcute pentru PC-ul meu (Ryzen 7 9850X3D, RTX 5060, Windows 11). Au căi fixe, de exemplu contul Steam `177599511`, CS2 în `C:\Program Files (x86)\Steam` și Process Lasso în `C:\Program Files\Process Lasso`. Pe alt PC trebuie schimbate înainte de rulare.

Toate scripturile care scriu ceva cer **PowerShell ca Administrator** și **CS2 închis**. Le pornești din folderul repo-ului:

```powershell
powershell -ExecutionPolicy Bypass -File .\<script>.ps1 <comanda>
```

## Scripturile

### `perfect-state.ps1`: salvează și readuce o stare bună

Salvează baza de setări NVIDIA, setările video și de joc din CS2, configurația Process Lasso, accelerația mouse-ului, core parking și launch options (doar notate).

| Comandă | Ce face |
|---|---|
| `save` | Salvare nouă în `saved-states\perfect-<data>` |
| `list` | Arată salvările |
| `restore` | Readuce ultima salvare (înainte salvează starea curentă) |
| `restore -WithConvars` | Readuce și crosshair-ul, sensibilitatea etc.; cere și Steam închis |

> **Nu folosi `restore` după un update de driver NVIDIA.** Copiază baza veche peste driverul nou. Pentru partea de NVIDIA folosește `nv-migrate.ps1`.

### `nv-migrate.ps1`: setările NVIDIA după un update de driver

Un update de driver șterge profilurile personalizate. Scriptul încarcă pentru câteva secunde baza salvată, citește doar valorile setate de mine, pune la loc baza driverului nou și aplică peste ea acele valori.

| Comandă | Ce face |
|---|---|
| `dump` | Doar citește: arată setările mele de pe driverul curent |
| `run -WhatIf` | Arată ce ar aplica, fără să aplice |
| `run` | Aplică și verifică; backup în `migrate-<data>\current` |

Ecranul poate clipi de două ori: serviciul NVIDIA se oprește și repornește.

### `cs2-nv.ps1`: setări experimentale NVIDIA doar pentru CS2

| Nume | Ce face | Risc |
|---|---|---|
| `os-vrr-off` | Oprește VRR-ul din Windows pentru CS2 | mic |
| `no-app-stats` | Oprește statisticile NVIDIA App | mic |
| `foreground-force` | Driverul tratează mereu CS2 ca fereastră activă | mic |
| `cmd-queue-low` | Coadă de comenzi mai mică; poate reduce latența, poate costa FPS | mediu |
| `present-async` / `present-sync` | Forțează modul de prezentare a cadrelor | mediu |
| `shader-threads-1` | Un singur fir de compilare a shaderelor, nu 4 | mediu |
| `rbar-off` | Oprește rBAR forțat doar pentru CS2 | mediu |
| `fastsync` | Fast Sync; poate sacada | mare |

`ultra` = primele patru. Comenzi: `list`, `status`, `apply <nume>`, `revert <nume>`, `restore` (scoate tot ce a pus scriptul).

### `restore-friday.ps1`: restaurarea din 8 noiembrie 2026

Folosit o singură dată, pentru a reveni la setările de vineri, 6 noiembrie, dintr-o copie Windows. Îl păstrez ca referință. Fișierele lui (`friday-snapshot\`) nu sunt în repo.

## Ce nu e în repo

Backup-urile, salvările și bazele de date NVIDIA (`saved-states\`, `friday-snapshot\`, `migrate-*`, `backup\`) rămân doar pe PC (vezi `.gitignore`). Conțin setări personale și fișiere binare de câte 2 MB.

## Unelte externe

### `tools\MSI_util_v3.exe`: MSI mode

Utilitar pentru Message Signaled Interrupts (MSI_util_v3, versiunea 3.0.0.0). Arată ce dispozitive folosesc MSI și permite schimbarea modului și a priorității întreruperilor.

- **Nu e semnat digital** și nu e făcut de mine. SHA256: `0142AFC21FE61AA4209A4B0D994D724F743718F1F42EC07E41FC63CC43FB6CA6`.
- Se rulează ca Administrator. Schimbările se aplică după restart.
- **Schimbă doar dispozitivele pe care le știi** (placa video, placa de rețea, controller-ul USB). MSI pe un dispozitiv care nu îl suportă poate da ecran albastru sau dispozitiv nefuncțional. Notează ce era înainte, ca să poți reveni.

### WinSux (nu e în repo, doar comanda)

```powershell
iwr 'https://github.com/FR33THYFR33THY/WinSux/raw/refs/heads/main/WinSux/winsux.ps1' -useb | iex
```

Script de „debloat” de la altcineva: descarcă și rulează imediat cea mai nouă versiune de pe GitHub, fără confirmare. **Nu are buton de anulare.** Din ce a citit Claude în cod pe 22 noiembrie 2026, printre altele:

- **Șterge driverele plăcii video** cu DDU (`-CleanAllGpus`) și repornește PC-ul de mai multe ori (inclusiv în Safe Mode).
- Dezactivează **UAC**, **VBS/HVCI**, SmartScreen, o parte din Windows Defender, BitLocker și blocklist-ul de drivere vulnerabile.
- Blochează update-urile de driver din Windows Update și amână update-urile cu un an.
- Scoate aplicații Store, Edge, OneDrive; dezactivează IPv6 și alte protocoale pe placa de rețea.
- Instalează 7-Zip, Visual C++ Redistributables, DirectX și browserul Helium.

După rulare trebuie reinstalat driverul NVIDIA, iar setările se refac cu `nv-migrate.ps1 run`. Verifică întâi dacă FACEIT mai pornește cu VBS și protecțiile dezactivate. Fă un punct de restaurare Windows **înainte**.

## Reguli învățate

- **Nu rula Hermes / „electricity-anti-lag”.** Nu face nimic pentru CS2, iar butonul de C-States lasă core parking la 1%. Verificare: `powercfg /query scheme_current sub_processor CPMINCORES` trebuie să arate `0x00000064`.
- O schimbare pe rând, testată cu 1% low și frametime, nu cu FPS-ul mediu.
- `Disable fullscreen optimizations` pe `cs2.exe` contează doar în **Fullscreen** exclusiv, nu în Fullscreen Windowed.
