
# -----------------------------------------------------------------------------
# Edition profile: PERSONAL. Built for one specific PC. The documented
# baseline below is only compared with what Windows reports in System
# overview; it never changes what is cleaned.
# -----------------------------------------------------------------------------
$script:Edition      = 'Personal'
$script:EditionTitle = 'aiznm CLEANER'
$script:EditionTag   = ''
$script:Baseline = @{
    CpuText = 'Intel Core i9-10900F, 10C/20T'; CpuMatch = '10900F'; Cores = 10; Threads = 20
    BoardText = 'ASUS PRIME B560-PLUS'; BoardMatch = 'B560-PLUS'
    BiosText = '2001 (2023-02-01)'; BiosVersion = '2001'
    MemText = '16 GB (2x8) CMK16GX4M2Z3600C18, DDR4-3600'; MemTotal = 16GB; MemSticks = 2; MemPart = 'CMK16GX4M2Z3600C18'; MemSpeed = 3600
    GpuText = 'MSI GeForce RTX 4060, 8 GB'; GpuMatch = 'RTX 4060'
    OsText = 'Windows 10 Home 22H2, build 19045.6466'; OsBuild = '19045'; OsUbr = 6466
    SecureBoot = $true
    DisplaysNote = 'Documented: AOC Q27G4SDR 2560x1440 up to 360 Hz; Samsung F24G3xTF 1920x1080 (120/144 Hz unconfirmed).'
    PlatformNote = 'The B560 + i9-10900F platform provides PCIe 3.0.'
}
