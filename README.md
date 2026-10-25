# Trip

在地图上找附近的加油站、EV 充电桩、休息区和厕所。覆盖 BC 全省。规格见 [SPEC.md](SPEC.md)。

## 装到手机上

用 USB 连上 iPhone，然后：

```bash
./deploy.sh
```

VS Code 里也可以按 `Ctrl+Shift+B`（"Deploy to iPhone" 任务）。用的是免费 Apple ID，**每 7 天要重新部署一次**。

只编译、不装手机：`xtool dev build`

## 数据

数据由 GitHub Actions（[.github/workflows/data.yml](.github/workflows/data.yml)）每天检查一次，到期的地区重新生成，发布到 `data` 分支，App 从那里下载。

- **改地区或更新频率**：编辑 [data/regions.yaml](data/regions.yaml)（GitHub 网页上改就行），下一次运行生效
- **立刻更新**：GitHub → Actions → Data → Run workflow，填地区 id（如 `bc,wa`），留空则只更新到期的
- **失败**：该地区保留上一版，GitHub 会发邮件；新数据点数比上一版少 20% 以上、或 App 解码不了，都算失败
- **`data` 分支**：`manifest.json`（各地区的版本、hash、数据来源、边界）、`regions/<id>.json`、`context/<id>.json`（无名厕所位置名的缓存）。每次强制覆盖，不留历史
- **密钥**：仓库 Settings → Secrets → Actions 里设 `AFDC_API_KEY`（不设就用限流的 `DEMO_KEY`）；`OCM_API_KEY` 可选，且地区的 `sources` 里要有 `ocm`
- 厕所推断规则（连锁品牌、图书馆等类别）在 [data/brands.yaml](data/brands.yaml)，`regions:` 下可以按地区加品牌
- 地区边界来自 Natural Earth（公有领域）

本地调试单个地区：

```bash
uv run data/build.py --region bc             # 用 data/cache/bc/ 的缓存，输出 data/out/bc.json
uv run data/build.py --region wa --refresh   # 重新下载
scripts/test-swift.sh data/out/wa.json       # 确认 App 能解码
```

- 公共 Overpass 服务器有时满载，脚本会自动重试并切换镜像
- 无名厕所的公园/街道名是逐个查的，只有新出现的厕所才会去查。全部重查用 `--refresh-context`（BC 全省约 40 分钟）

## 测试（都在 Linux 上跑）

```bash
uv run --with pytest --with pyyaml --with requests pytest data   # 数据脚本、营业时间解析
scripts/test-swift.sh [文件...]                                  # App 的营业时间判断、日出日落，以及解码数据文件
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
  regions.yaml           发布哪些地区、多久更新一次
  build.py               单个地区的数据管线
  update.py              生成到期的地区并写 manifest（Actions 里跑）
  hours.py               营业时间解析
  brands.yaml            厕所推断规则
scripts/test-swift.sh    在 Linux 上跑 App 的 Swift 测试
.github/workflows/       定时更新数据
```
