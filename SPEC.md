# Trip V1 规格

个人项目：一个 iOS App，在地图上找附近的**加油站、EV 充电桩、休息区、厕所**。
只装在自己的 iPhone 上（免费 Apple ID，每 7 天重新签名），不上架、不变现。

## 功能

- 地图显示四类地点：加油站、EV 充电桩、休息区、厕所
- **圆心 = 地图中心**：打开时以我的位置为中心；拖动地图后列表跟着变；有"回到我的位置"按钮
- 半径档位 2 / 5 / 10 / 25 / 50 km，默认 10 km，记住上次的选择
- 底部列表按距离排序
- 顶部四个分类开关（可多选，默认全开）；地图缩小时点自动聚合；厕所有"只看公共"快捷过滤
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
- **去重**：同类点距离很近（默认 50 m，休息区 300 m）视为同一个，官方来源优先，其他来源补齐缺失字段
- **产出**：`data/build.py` 手动运行，生成 `Sources/Trip/Resources/pois.json` 打包进 App。更新数据 = 重跑脚本 + 重新部署
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

油价、前方模式和路线模式、App 内导航、账号和用户上报、CarPlay、后台定位和提醒、
EV 续航规划和实时空闲状态、离线底图、法语界面。
