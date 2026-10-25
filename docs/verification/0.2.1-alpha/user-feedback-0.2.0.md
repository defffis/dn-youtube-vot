# Наблюдение пользователя, 25.10.2026

YouTube 21.40.5, iOS 27.0.1, GBox, DNVOT 0.2.0-alpha.
Пользователь нашёл категорию настроек и смог войти в аккаунт. В плеере значок
перевода не появился, хотя `Player buttons: 1`. Native UI hooks 11,
Settings sections built 8, Player menus decorated 1.

Для ролика 0flkwrqq28s: POST /session/create HTTP 200;
POST /video-translation/translate HTTP 200; VOT status=1, enabled YES,
status «Перевод готов», lively requested YES. Контент 185.834 с, аудио 185.648 с,
timeControlStatus 0. Это подтверждает получение готового URL перевода;
слышимость звука и фактический тип возвращённого голоса не подтверждены.
Отсутствие source URL не препятствовало этому готовому результату.

После получения отчёта изменена только интеграция/отрисовка значка и
диагностика аудиоплеера. Протокол, авторизация, Keychain и sync policy не изменялись.
