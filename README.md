---
name: linux-ssh-analysis
description: >
  Use this skill whenever the user wants to connect to a remote Linux server via SSH
  and perform systematic analysis of its performance, health, logs, or processes.
  Triggers include: "połącz się przez SSH", "sprawdź serwer", "analiza serwera",
  "zbadaj metryki", "sprawdź logi", "diagnozuj procesy", "monitoruj obciążenie",
  "wydajność serwera", "debug serwera", or any request to investigate CPU/RAM/disk/network
  on a remote host. Also use when the user asks to identify bottlenecks, investigate
  slow response times, audit running processes, or perform a Linux health check —
  even if they do not explicitly say "SSH". This skill applies Addy Osmani's
  performance investigation methodology: measure first, hypothesize second, fix last.
---

# Linux SSH Analysis Skill

Systematyczna analiza zdalnego serwera Linux przez SSH zgodnie z metodologią
**Addy Osmaniego**: mierz → rozumiej → optymalizuj. Nie zgaduj — zbieraj dane.

---

## Filozofia metodologii (Addy Osmani)

> "You can't optimize what you can't measure."

Trzy zasady, których zawsze przestrzegamy:

1. **Measure first** — zbierz twarde dane przed wyciąganiem wniosków.
2. **Identify the bottleneck** — jedno wąskie gardło dominuje; znajdź je.
3. **Iterate, don't over-engineer** — najprostsze rozwiązanie, które eliminuje bottleneck.

Sekwencja analizy: **Overview → Metrics → Processes → Logs → Diagnosis → Action**.

---

## Faza 0 — Nawiązanie połączenia SSH

Przed analizą ustal dane dostępowe z użytkownikiem:

```
host: <IP lub FQDN>
port: 22 (lub inny)
user: <nazwa użytkownika>
auth: klucz SSH lub hasło
```

Zaproponuj użytkownikowi uruchomienie lokalnego skryptu-kolekcjonera
(`collector.sh` — patrz niżej) i wklejenie wyników, jeśli Claude nie ma
bezpośredniego dostępu do basha na hoście docelowym. Alternatywnie poproś
o skopiowanie outputów kolejnych komend ręcznie.

---

## Faza 1 — Szybki przegląd (30-second overview)

Cel: uzyskać ogólny obraz systemu w < 1 minucie. Uruchom poniższe komendy
sekwencyjnie lub użyj `collector.sh`.

```bash
# Tożsamość i uptime
uname -a
hostname -f
uptime
last reboot | head -5

# Zasoby — migawka
free -h
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
cat /proc/loadavg
```

**Interpretacja load average** (Osmani: zawsze normalizuj do liczby vCPU):

```
load / vCPU < 0.7   → OK
load / vCPU 0.7–1.0 → uważaj
load / vCPU > 1.0   → bottleneck CPU lub I/O wait
```

Aby sprawdzić liczbę vCPU: `nproc` lub `lscpu | grep '^CPU(s):'`

---

## Faza 2 — Metryki szczegółowe

### 2a. CPU

```bash
# Migawka top 10 procesów wg CPU
ps aux --sort=-%cpu | head -11

# Statystyki CPU (1 s, 5 próbek)
mpstat -P ALL 1 5        # wymaga sysstat
# lub
vmstat 1 5

# Analiza I/O wait (wysoki iowait = bottleneck dyskowy/sieciowy, nie CPU)
iostat -xz 1 5           # wymaga sysstat
```

**Sygnały alarmowe:**
- `%iowait > 20%` → dysk lub sieć blokuje CPU
- `%steal > 5%` → wirtualizacja kradnie czas CPU (problem hosta)
- `%si` (software interrupt) wysoki → sieć lub NIC flooding

---

### 2b. Pamięć RAM

```bash
free -h
# Szczegóły
cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty'

# Ranking procesów wg RAM
ps aux --sort=-%mem | head -11

# Czy był OOM killer?
dmesg -T | grep -i 'oom\|killed process' | tail -20
journalctl -k --since "24h ago" | grep -i oom | tail -20
```

**Interpretacja:**
- `MemAvailable` < 10% RAM → realny niedobór pamięci
- `Swap used` > 0 → system zaczął swapować (duże spowolnienie)
- Wpisy OOM killer → procesy były zabijane z powodu braku RAM

---

### 2c. Dysk

```bash
# Zajętość
df -hT --exclude-type=tmpfs

# I/O w czasie rzeczywistym
iostat -xz 1 5
# Kluczowe kolumny: %util (nasycenie urządzenia), await (opóźnienie ms), r/s, w/s

# Największe katalogi
du -sh /* 2>/dev/null | sort -rh | head -20
du -sh /var/log/* 2>/dev/null | sort -rh | head -10

# Inody (często zapomniany bottleneck)
df -i
```

**Sygnały alarmowe:**
- `%util > 80%` → dysk nasycony
- `await > 20 ms` (HDD) lub `> 2 ms` (SSD/NVMe) → wysokie latencje I/O
- `df -i` pokazuje 100% → brak inodów mimo wolnego miejsca

---

### 2d. Sieć

```bash
# Interfejsy i statystyki
ip -s link
ss -s                    # podsumowanie socketów

# Aktywne połączenia
ss -tunap | head -40
# lub
netstat -tunap 2>/dev/null | head -40

# TIME_WAIT / CLOSE_WAIT nagromadzenie
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# Ruch w czasie rzeczywistym (jeśli dostępne)
iftop -t -s 5 2>/dev/null || nload -t 1000 -i 102400 -o 102400 2>/dev/null
```

**Sygnały alarmowe:**
- Tysiące `TIME_WAIT` → tunning `net.ipv4.tcp_tw_reuse` lub problem z keepalive
- `CLOSE_WAIT` nagromadzenie → bug aplikacji (nie zamyka połączeń)
- Retransmisje: `ss -ti` i sprawdź pole `retrans`

---

## Faza 3 — Analiza procesów

```bash
# Top interaktywny (q żeby wyjść po 10s)
top -b -n 2 -d 5 | tail -40

# Drzewo procesów
pstree -p | head -60

# Procesy zombie
ps aux | awk '$8 == "Z"'

# Procesy D-state (uninterruptible sleep — czekają na I/O)
ps aux | awk '$8 == "D"'

# Otwarte pliki i deskryptory — wykryj wycieki
lsof -n | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
ulimit -n                # limit deskryptorów dla bieżącej sesji
cat /proc/sys/fs/file-max
cat /proc/sys/fs/file-nr  # używane / wolne / max
```

**Sygnały alarmowe:**
- Procesy D-state przez dłuższy czas → I/O blocked (dysk lub NFS)
- Zombie processes > 0 → rodzic nie zbiera exit code (bug aplikacji)
- Deskryptory bliskie limitu → `too many open files` błędy

---

## Faza 4 — Analiza logów

### Systemowe

```bash
# Ostatnie błędy kernela
dmesg -T --level=err,crit,alert,emerg | tail -30

# Systemd journal — błędy ostatnie 24h
journalctl -p err --since "24h ago" --no-pager | tail -50

# Auth log — nieautoryzowane próby
journalctl _SYSTEMD_UNIT=sshd.service --since "24h ago" | grep -i 'fail\|invalid\|error' | tail -20
grep -i 'failed\|invalid user' /var/log/auth.log 2>/dev/null | tail -20
```

### Aplikacyjne (dostosuj ścieżki)

```bash
# Nginx / Apache
tail -100 /var/log/nginx/error.log 2>/dev/null
tail -100 /var/log/apache2/error.log 2>/dev/null

# MySQL / MariaDB
tail -100 /var/log/mysql/error.log 2>/dev/null

# Własna aplikacja — szukaj wzorców
journalctl -u <service-name> --since "1h ago" --no-pager | grep -iE 'error|exception|fatal|panic|timeout' | tail -50
```

### Wzorce logów wg Osmaniego — szukaj sygnałów, nie szumu

| Wzorzec | Znaczenie |
|---|---|
| `timeout` / `timed out` | Powolne zależności (DB, API) |
| `connection refused` | Usługa nie działa lub zły port |
| `out of memory` / `OOM` | Niedobór RAM |
| `too many open files` | Wyczerpanie deskryptorów |
| `disk full` / `no space left` | Brak miejsca |
| `segfault` / `SIGSEGV` | Bug w kodzie lub bibliotece |
| `SIGKILL` | OOM killer lub ręczne zabicie |

---

## Faza 5 — Usługi systemd

```bash
# Które usługi padły lub są degraded?
systemctl --failed

# Status kluczowych usług
systemctl status nginx mysql postgresql redis docker 2>/dev/null | grep -A5 'Active:'

# Ile czasu zajął boot?
systemd-analyze
systemd-analyze blame | head -20
```

---

## Faza 6 — Synteza i raport

Po zebraniu danych sporządź raport w tej strukturze:

```
## Raport analizy serwera: <hostname> — <data>

### Stan ogólny: [OK / UWAGA / KRYTYCZNY]

### Bottlenecks (ranked by impact)
1. <największy problem> — evidence: <dane które to potwierdzają>
2. ...

### Metryki kluczowe
| Metryka | Wartość | Próg | Ocena |
|---------|---------|------|-------|
| CPU load (normalized) | X.X | < 0.7 | ✅/⚠️/🔴 |
| RAM available | X GB / X% | > 10% | ... |
| Disk util (max) | X% | < 80% | ... |
| Swap used | X MB | 0 | ... |
| OOM events (24h) | X | 0 | ... |

### Logi — anomalie
- <co znaleziono w logach>

### Rekomendacje (Osmani: smallest change, biggest impact first)
1. **Natychmiast**: <akcja>
2. **Krótkoterminowo**: <akcja>
3. **Długoterminowo**: <akcja>
```

---

## Skrypt kolektor (collector.sh)

Jeśli użytkownik chce zebrać wszystkie dane jednym poleceniem i wkleić wynik:

```bash
#!/bin/bash
# collector.sh — zebranie metryk dla analizy
# Użycie: bash collector.sh 2>&1 | tee server_report.txt

SEP="=========================================="

echo "$SEP"; echo "=== SYSTEM INFO ==="; echo "$SEP"
uname -a; hostname -f; uptime; echo "vCPU: $(nproc)"

echo "$SEP"; echo "=== LOAD & CPU ==="; echo "$SEP"
cat /proc/loadavg
vmstat 1 3

echo "$SEP"; echo "=== MEMORY ==="; echo "$SEP"
free -h
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty'

echo "$SEP"; echo "=== DISK ==="; echo "$SEP"
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
df -i --exclude-type=tmpfs

echo "$SEP"; echo "=== I/O ==="; echo "$SEP"
iostat -xz 1 3 2>/dev/null || echo "iostat unavailable (install sysstat)"

echo "$SEP"; echo "=== TOP PROCESSES CPU ==="; echo "$SEP"
ps aux --sort=-%cpu | head -11

echo "$SEP"; echo "=== TOP PROCESSES MEM ==="; echo "$SEP"
ps aux --sort=-%mem | head -11

echo "$SEP"; echo "=== NETWORK ==="; echo "$SEP"
ss -s
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

echo "$SEP"; echo "=== FAILED SERVICES ==="; echo "$SEP"
systemctl --failed 2>/dev/null

echo "$SEP"; echo "=== DMESG ERRORS ==="; echo "$SEP"
dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -20

echo "$SEP"; echo "=== JOURNAL ERRORS (1h) ==="; echo "$SEP"
journalctl -p err --since "1h ago" --no-pager 2>/dev/null | tail -30

echo "$SEP"; echo "=== OOM CHECK ==="; echo "$SEP"
dmesg -T 2>/dev/null | grep -i 'oom\|killed process' | tail -10

echo "$SEP"; echo "=== OPEN FILES ==="; echo "$SEP"
cat /proc/sys/fs/file-nr
lsof -n 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

echo "Done. Paste this output to Claude for analysis."
```

Instrukcja dla użytkownika:
```bash
curl -O https://your-host/collector.sh  # lub wklej ręcznie
bash collector.sh 2>&1 | tee server_report.txt
# Następnie wklej zawartość server_report.txt do czatu
```

---

## Szybka ściąga — najczęstsze bottlenecki

| Symptom | Pierwsza komenda | Podejrzany winowajca |
|---|---|---|
| Serwer wolny, load wysoki | `vmstat 1 5` → kolumna `wa` | I/O wait → dysk |
| Serwer wolny, load niski | `ss -s` → ESTABLISHED | Sieć / połączenia |
| OOM killer aktywny | `dmesg | grep oom` | Za mało RAM, memory leak |
| Brak miejsca na dysku | `du -sh /var/log/*` | Logi bez rotacji |
| Procesy D-state | `ps aux | awk '$8=="D"'` | NFS timeout, dysk failing |
| Brak inodów | `df -i` | Miliony małych plików |
| Port nie odpowiada | `ss -tlnp | grep <port>` | Usługa nie działa |

---

## Uwagi bezpieczeństwa

- Nigdy nie loguj się jako `root` jeśli można użyć `sudo`.
- Nie przechowuj haseł SSH w historii komend — używaj kluczy.
- Po analizie sprawdź `~/.bash_history` i wyczyść jeśli potrzeba.
- Komendy diagnostyczne są read-only — ta metodologia nie modyfikuje systemu.
