# Trip

在地图上找附近的加油站、EV 充电桩、休息区和厕所。覆盖 BC 全省。规格见 [SPEC.md](SPEC.md)。

## 装到手机上

用 USB 连上 iPhone，然后：

```bash
./deploy.sh
```

VS Code 里也可以按 `Ctrl+Shift+B`（"Deploy to iPhone" 任务）。用的是免费 Apple ID，**每 7 天要重新部署一次**。

只编译、不装手机：`xtool dev build`

## 更新数据

```bash
uv run data/build.py --refresh   # 重新下载所有数据源（不加 --refresh 则用 data/cache/ 的缓存）
scripts/test-swift.sh            # 确认 App 能解码新数据
./deploy.sh
```

- 生成的文件是 `Sources/Trip/Resources/pois.json`
- 厕所推断规则（连锁品牌、图书馆等类别）在 [data/brands.yaml](data/brands.yaml)，改完重跑脚本即可
- 可选环境变量：`AFDC_API_KEY`（不设就用限流的 `DEMO_KEY`，偶尔跑一次够用）、`OCM_API_KEY`（设了才会加入 Open Charge Map 数据）
- 公共 Overpass 服务器有时满载，脚本会自动重试并切换镜像
- 无名厕所的公园/街道名是逐个查的，结果缓存在 `data/cache/osm_context.json`，只有新出现的厕所才会去查。全部重查用 `--refresh-context`（BC 全省约 40 分钟）

## 测试（都在 Linux 上跑）

```bash
uv run --with pytest --with pyyaml --with requests pytest data   # 数据脚本、营业时间解析
scripts/test-swift.sh                                            # App 的营业时间判断、日出日落，以及解码 pois.json
```

## 目录

```
Sources/Trip/
  TripApp.swift          入口
  POIModel.swift         pois.json 的数据结构（只依赖 Foundation，Linux 上可测）
  OpeningHours.swift     营业状态判断 + 日出日落计算（只依赖 Foundation）
  POI.swift              分类、过滤、图标、显示名称
  POIStore.swift         加载数据 + 半径查询
  LocationManager.swift  定位（仅"使用 App 期间"）
  MapsLauncher.swift     跳 Google Maps / Apple Maps
  Views/                 地图、过滤条、底部列表、详情、关于
data/
  build.py               数据管线
  hours.py               营业时间解析
  brands.yaml            厕所推断规则
scripts/test-swift.sh    在 Linux 上跑 App 的 Swift 测试
```
