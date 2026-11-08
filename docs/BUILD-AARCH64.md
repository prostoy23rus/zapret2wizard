# Кросс-сборка сканера под роутер (aarch64 musl)

Роутеры на ARM64 (aarch64_cortex-a53, OpenWrt) требуют статический бинарь
`blockcheckw` под `aarch64-unknown-linux-musl`. Собрать его можно из Windows
через WSL — без отдельной Linux-машины.

## 1. Подготовка WSL (один раз)

```powershell
# включить компоненты (нужны права администратора, затем перезагрузка)
dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
# после перезагрузки
winget install --id 9P9TQF7MRM4R --source msstore
wsl --install -d Ubuntu --no-launch
```

## 2. Тулчейн (один раз)

```powershell
wsl -d Ubuntu -u root -- bash /mnt/e/AI/zapret2wizard/scripts/wsl-setup.sh
```

Скрипт ставит `build-essential`, `cmake`, `pkg-config`, Rust (rustup), цель
`aarch64-unknown-linux-musl` и кросс-компилятор `aarch64-linux-musl-gcc`
из musl.cc. Проверка: в конце печатается `SETUP_OK`.

## 3. Сборка

```powershell
wsl -d Ubuntu -u root -- bash /mnt/e/AI/zapret2wizard/scripts/wsl-build.sh
```

Результат копируется в `E:\deepseek\build\blockcheckw-aarch64`.
Ожидаемый вид: `ELF 64-bit LSB executable, ARM aarch64, statically linked`.

## 4. Установка на роутер

```powershell
pscp -scp -pw <пароль> E:\deepseek\build\blockcheckw-aarch64 root@192.168.1.1:/tmp/blockcheckw.new
plink -batch -load RR -pw <пароль> "cp /usr/bin/blockcheckw /root/blockcheckw.bak; cp /tmp/blockcheckw.new /usr/bin/blockcheckw; chmod +x /usr/bin/blockcheckw; /usr/bin/blockcheckw --version"
```

Проверка: `blockcheckw --version` должен показать версию из `Cargo.toml`.
Текущая — `0.17.0`.

## 5. Проверка после установки

```sh
blockcheckw-helper test preset_youtube https://googlevideo.com
blockcheckw-helper start --target preset_youtube --mode smart --auto-apply 0
```

После скана таблица `inet zapret2wizard` должна существовать, а служба —
быть в состоянии `running`. Это проверяется автоматически в
`restart_dpi_service` (хелпер восстанавливает службу, если таблица исчезла).

## Откат

```sh
cp /root/blockcheckw.bak /usr/bin/blockcheckw
```

## 6. Проверки CI без отдельной Linux-машины

В том же WSL можно прогнать весь набор проверок GitHub CI:

```powershell
wsl -d Ubuntu -u root -- bash /mnt/e/AI/zapret2wizard/scripts/wsl-verify.sh
```

Скрипт выполняет `cargo fmt --check`, `cargo clippy -- -D warnings` и
`cargo test --lib --features otel`. На момент написания: форматирование — ок,
clippy без предупреждений, 353 теста прошли.

Требуется один раз доустановить компоненты:

```bash
rustup component add rustfmt clippy
```
