# Проверка 0.4.2 / Verification

Дата: 27.10.2026. Обычный релиз на основе 0.4.2-test.1 (`888bfd0`).

- Пользователь сообщил: «он был протестирован, работает хорошо» и предоставил скриншоты плеера и настроек. Это пользовательская проверка, без полного протокола матрицы устройств.
- Исходники src побайтно совпадают с 0.4.2-test.1 после замены строк версии `0.4.2-test.1` → `0.4.2`. Новых изменений логики нет.
- Linux ARM64 build, Clang/LLD 18.1.3, iOS 16+, -Werror / fatal warnings.
- UBSan core tests, Google Protobuf request/ETA parity and repository links checked; see tests.log.
- Mach-O constructor, UUID, system dependencies and ad-hoc page hashes verified; see macho-verification.json.
- SHA-256 dylib: `8f3366ddb052ba24d725299e9e83830db6e3c6e9e16d31e51804c63bf1ee8f53`.
- Добавлены RU/EN README и пользовательские инструкции, скриншоты. Русский остаётся основным; UI не локализован на английский.
- Разработчик не выполнял новый прогон на подключённом iPhone. Причина старой перезагрузки watch не считается установленной; длительный фон/TTL/все устройства не объявлены проверенными.

English: the user tested 0.4.2-test.1, confirmed good operation and supplied screenshots. This stable build changes only runtime version strings. Host build/tests were repeated; this is not a complete developer-run device matrix or proof of the earlier reload issue being fixed.
