# assets

Файлы, которые образ Valhalla иначе скачивает с GitHub при первой сборке
тайлов. В проде GitHub недоступен, поэтому они лежат в репозитории, а
`setup.sh` кладет их в `custom_files/<сезон>/` перед запуском.

| Файл | Откуда | Лицензия |
|---|---|---|
| `default_speeds.json` | https://raw.githubusercontent.com/OpenStreetMapSpeeds/schema/master/default_speeds.json | MIT |

Снимок от 2026-08-28, sha256 `9953f78c2407b8d2e3701fce6cc93c6a91b207a365a5d2f5564a6d1c231e5ba7`.
Обновление: скачать файл заново на машине с интернетом и заменить здесь,
при следующем пересоздании тайлсета он попадет в сборку.
