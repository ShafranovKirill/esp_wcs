# Документация

| Файл | Содержание |
| --- | --- |
| [tz.md](tz.md) | техническое задание (рабочая версия в markdown) |
| [roadmap.md](roadmap.md) | план работ и статус |
| [bastion.md](bastion.md) | бастион: архитектура (DDD), центр сертификации, интерфейс, запуск |
| [access.md](access.md) | бастион: сотрудники, группы, роли и права на папки, дерево папок, карты (проект) |
| [protocol.md](protocol.md) | WCS Link — протокол ESP ↔ бастион |
| [security.md](security.md) | безопасность: активы, модель нарушителя, STRIDE, ограничения, проверка |
| [led.md](led.md) | индикация RGB-светодиода: цвета, свечение, подсказки кнопки |
| [setup.md](setup.md) | установка ESP-IDF, сборка, прошивка, таблица разделов |
| [hardware/esp32-s3-n16r8-board.md](hardware/esp32-s3-n16r8-board.md) | справочник по плате, распиновка, проверка экземпляра |
| [hardware/console-wiring.md](hardware/console-wiring.md) | подключение консоли: ESP → MAX3232 DB9 → KS-444M → RJ45, монтажная и принципиальная схемы, кнопка GPIO4, проверенные распиновки и порядок проверки |
| [hardware/schematics/README.md](hardware/schematics/README.md) | комплект чертежей WCS.01 и WCS.02 для диплома: SVG и PNG, правила оформления |
| [hardware/sdkconfig.defaults.n16r8](hardware/sdkconfig.defaults.n16r8) | проверенная база `sdkconfig.defaults` для платы |
| [source/](source/) | исходные документы (оригинал ТЗ в .docx) |

Расхождение с ТЗ: RGB-светодиод на этой плате — **GPIO48**, а не GPIO38 (проверено).
