# Trip V1 规格

个人项目：一个 iOS App，在地图上找附近的**加油站、EV 充电桩、休息区、厕所**。
只装在自己的 iPhone 上（免费 Apple ID，每 7 天重新签名），不上架、不变现。

## 功能

- 地图显示四类地点：加油站、EV 充电桩、休息区、厕所
- **圆心 = 地图可见区域的中心**（扣掉顶部过滤条和底部列表）：打开时以我的位置为中心；拖动地图后列表跟着变；有"回到我的位置"按钮
- 半径档位 100 m / 500 m / 1 / 2 / 5 / 10 / 25 / 50 km，默认 10 km，记住上次的选择
- 底部列表按距离排序
- 顶部四个分类开关（可多选，默认全开）；地图缩小时点自动聚合
- 子过滤：厕所"只看公共"；EV "只看快充"和接口类型（NACS / CCS / CHAdeMO / J1772，多选）
- **营业状态**：列表和详情显示"营业中，几点关门 / 已关门，几点开门"；"Open now"过滤隐藏确定已关门的地点，营业时间未知的保留
- 无名厕所显示所在公园或附近街道，例如 "Washroom · Kitsilano Beach Park"
- 点击地点弹出详情卡片，按类别显示字段；"导航"按钮优先跳 Google Maps，没装则跳 Apple Maps；App 内不做导航
- 拒绝定位权限时，地图默认显示温哥华市中心
- 单位 km，界面只做英文；每类地点一个 SF Symbol 图标
- 设置页注明数据来源（满足 OSM ODbL 等授权要求）

## 厕所

尽量多收：公共、加油站和休息区、商场/图书馆/社区中心、餐厅/咖啡店。

- **使用权限**：公共（public）/ 仅限顾客（customers）/ 未知（unknown）
- **可信度**：官方数据（official）/ OSM 明确标注（osm）/ 按品牌或类别推断（inferred，界面明确标出）
- 品牌和类别推断规则在 [data/brands.yaml](data/brands.yaml)，可随时增删

## 数据

| 类别 | 数据源 |
|---|---|
| 加油站、厕所、餐厅/咖啡店等 | OpenStreetMap（Overpass API） |
| EV 充电桩 | AFDC API（`developer.nlr.gov`，原 NREL；覆盖加拿大，数据来自 NRCan）为主，Open Charge Map 补充（需要 key，可选） |
| 公共厕所 | City of Vancouver 开放数据 `public-washrooms` |
| 休息区 | DataBC `MOT_REST_AREAS_SP`（WFS） |

- **覆盖**：BC 全省；校对集中在温哥华
- **营业时间**：[data/hours.py](data/hours.py) 把各来源的写法统一解析成每周时间表（OSM 约 95%、AFDC 约 98% 能解析；季节性规则不支持，原文照常显示）。dawn/dusk/sunrise/sunset 由 App 按地点和日期计算。全年开放的 BC 休息区视为 24 小时
- **无名厕所的位置名**：用 Overpass 查每个厕所所在的公园/设施和 60 m 内的街道，按厕所缓存（本地在 `data/cache/<地区>/osm_context.json`，Actions 里在 `data` 分支的 `context/<地区>.json`）
- **去重**：同类点距离很近（默认 50 m，休息区 300 m）视为同一个，官方来源优先，其他来源补齐缺失字段
- **产出**：V1 是 `data/build.py` 手动运行，生成 `Sources/Trip/Resources/pois.json` 打包进 App。V2 改为后端定时生成、App 下载，见下
- **字段**
  - 通用：名称、类别、经纬度、地址、开放时间、数据来源
  - 厕所：使用权限、可信度、无障碍、婴儿换尿布台、是否收费
  - 充电桩：接口类型（CCS / NACS / CHAdeMO / J1772）、最大功率、充电网络、DC 快充和 L2 桩数、价格
  - 加油站：品牌、是否有柴油、是否有便利店
  - 休息区：公路编号、行驶方向、厕所数量和类型、是否全年开放、是否容纳大货车

## 技术

- SwiftUI + MapKit（地图用 `MKMapView` 包装，借用原生聚合），最低 iOS 17
- 在 Linux 上用 xtool 构建，只在真机测试
- 只申请"使用 App 期间"的定位权限
- App 名 Trip，bundle ID `com.larryw.Trip`

## V1 不做

油价、前方模式和路线模式（路线模式见 V2）、App 内导航、账号和用户上报、CarPlay、后台定位和提醒、
EV 续航规划和实时空闲状态、离线底图、法语界面。

---

# V2 计划

仍然只有我一个用户，没有账号。分三步，每步都能单独发布。

## 1. 数据后端（GitHub Actions）

- 仓库公开（`nessusing/trip`）。地区和更新频率写在 `data/regions.yaml`，在 GitHub 上编辑就是"后台"
- 先做 BC + WA；数据按省/州一个文件。WA 及以后的地区只用 OSM + AFDC；各地官方数据源按需作为可选来源加入
- workflow 每天跑一次，只重建到期的地区（默认每 3 天）；也可以在 GitHub 上手动触发并指定地区。不做按需生成
- 发布前检查：pytest、App 的 Swift 模型能解码、点数比上一版少 20% 以上则拒绝。失败的地区保留上一版，GitHub 发邮件
- 产出放在 `data` 分支（每次强制覆盖，不留历史）：`manifest.json`（各地区版本、sha256、大小、数据格式版本、数据来源、简化边界）、`regions/<id>.json`、`context/<id>.json`
- 每个地点保留一个 `source`；manifest 记录每个地区用了哪些来源。多数据源比对、按优先级选最准的来源以后再做
- 品牌规则：全局 `brands.yaml` + 按地区覆盖
- AFDC 用自己的 key（GitHub Secret），不用 OCM

## 2. App 下载数据

- App 不再打包 `pois.json`，从 `raw.githubusercontent.com` 的 `data` 分支下载，存到 Application Support，之后离线可用
- 启动时、以及回到前台时（最多每几小时一次）检查 manifest，sha256 变了才下载；"关于"页有"检查更新"按钮，并显示各地区的数据日期
- 默认自动下载所有地区。全新安装且没网时显示"还没有数据，请联网下载"

## 3. 路线模式

- 保留现有的"附近"模式，新增路线模式
- 输入目的地（`MKLocalSearchCompleter`）→ 一条驾车路线（`MKDirections`）→ 沿途列表按沿路线的里程排序
- 走廊宽度 500 m / 1 / 2 / 5 km；现有的分类、Open now、EV 过滤照常生效
- 起点和终点都不在覆盖范围内：提示没有数据。路线部分出了覆盖范围：照常显示覆盖段，并提示数据不完整、缺哪些地区（对未覆盖段用 `CLGeocoder` 反查省/州名）
- 以后再做：备选路线、行驶中隐藏已开过的点、为无信号路段缓存路线、DriveBC 路况
