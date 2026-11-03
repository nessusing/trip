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

## 3. 目的地与路线

为 road trip 设计。行驶中真正有用的是"前方某一段附近有什么"，而不是把整条路线沿途的点全部列出来，所以路线模式的核心是**让搜索圆心沿路线拖动**。现有的"附近"模式保持不变。

### 3a. 目的地搜索（短途）

- 底部列表顶上加搜索框，输入时用 `MKLocalSearchCompleter` 联想地址和地名（优先当前地图附近）
- 选中后在目的地放一个大头针，地图和搜索圆跳过去，列表显示目的地周围的服务，跟平时拖地图一样
- 目的地卡片上有"路线"和"×"（清除）两个按钮。没有单独的模式开关：选了目的地并点"路线"就进入路线模式，点 × 回到附近模式

### 3b. 路线模式（长途）

- 从我的位置到目的地，用 `MKDirections` 算驾车路线并画在地图上；没有定位权限时提示需要定位
- **搜索圆心吸附在路线上**，不再跟随地图中心；拖地图只是看地图，不改变搜索位置
- 两种方式移动圆心，两者同步：
  - 地图上的拖柄：手指拖动时投影到路线上最近的点
  - 底部的滑条：从我当前所在位置到终点，标着"前方 xx km · 约 xx 分钟"；拖滑条时地图跟着圆心走
- 圆心只能在我当前位置之前；我开过了圆心所在的位置，圆心跟着我往前推
- 半径、分类、Open now、EV 过滤照常生效；列表按沿路线的先后排序，每项显示"前方 xx km · 约 xx 分钟"（时间按路线总时长按比例估算）；离路线 5 km 以上的点只显示直线距离，标"离路线较远"
- **覆盖范围**：路线经过没有数据的地区时，显示"数据不完整：缺 Alberta"（对未覆盖的路段用 `CLGeocoder` 反查省/州名）；整条路线都没有数据时只显示提示

### 3c. 增强

- **前方最近一键跳转**：每个分类一个按钮（下一个厕所 / 加油站 / 充电桩 / 休息区），把圆心跳到圆心之后、离路线 2 km 以内的第一个符合过滤条件的点
- **备选路线**：请求最多 3 条路线，都画在地图上（选中的高亮），在底部用按钮切换，各自标出里程和时间
- **缓存路线**：选中的路线（折线、里程、时长、目的地）存到手机上，重新打开 App 时恢复，没信号时也能用。底图是否离线可用取决于 Apple 地图缓存，不保证

以后再说：偏离路线后自动重新规划、DriveBC 路况（见下面「候选数据源」）。

---

# V3 计划：车机网页版

同样的功能做成一个网页，开在 **Tesla 车机浏览器**里（手机上也是同一个页面）。动机：行驶中真正要找厕所和加油站的时刻，人在车里看的是车机屏幕，不是手机；而且网页版没有免费 Apple ID 每 7 天重新签名的问题。

**iOS 版继续留着，分工明确**：iOS 版负责离线（数据下载到手机，山里没信号也能用），网页版负责车机。所以 V3 不做离线 —— 没信号的场景归 iOS 版。

分步发布，每步能单独用。

## 1. 放哪里、和数据怎么对齐

- 网页客户端放本仓库的 `web/`，**不单独开仓、不放 tesla-video-streamer 的仓库**。唯一决定性的理由：紧的耦合是数据契约（`manifest.json` / `regions/<id>.json` 的字段名、[data/hours.py](data/hours.py) 吐出的周时间表格式、[data/brands.yaml](data/brands.yaml) 的 `credibility` 取值），管线一改客户端必须同步改，同仓一个 commit 改完，不会版本漂移。和视频播放器共享的只有车机屏幕尺寸和几段手势 CSS —— 那是抄一次的事，不是持续依赖
- 数据管线、GitHub Actions、`data` 分支**完全不动**。网页直接 fetch 同样的文件
- 完全在线：打开页面拉 `manifest.json`，再拉需要的地区（BC 那个 2.9 MB，gzip 后不到 1 MB），同一次会话留在内存里。不装 Service Worker，不做 Cache API 缓存
- **双实现清单**：这两对逻辑在 Swift 和 JS 里各有一份，必须同步，改一边就得改另一边
  | 逻辑 | Swift | JS |
  |---|---|---|
  | 营业时间 + 日出日落 | [Sources/Trip/OpeningHours.swift](Sources/Trip/OpeningHours.swift) | `web/hours.js` |
  | 路线吸附、沿路距离、走廊索引、覆盖范围 | [Sources/Trip/RouteMath.swift](Sources/Trip/RouteMath.swift) | `web/route.js` |

  [scripts/test-swift.sh](scripts/test-swift.sh) 里现成的用例当两边共同的黄金答案：同一组输入和期望值，Swift 和 JS 各跑一遍

## 2. 换掉的 Apple 服务

| V1/V2 用的 | 网页版用什么 | 说明 |
|---|---|---|
| `MKMapView` 底图 | MapLibre GL JS + 自托管 [Protomaps](https://protomaps.com) PMTiles（BC+WA 一个文件） | Caddy 的 `file_server` 原生支持 Range，不用写代码。零 API key、零配额。文件体积要实测，z14 估计几 GB |
| `MKMapView` 原生聚合 | MapLibre 内置 cluster（Supercluster） | 等价 |
| `MKLocalSearchCompleter` 目的地联想 | 自托管 Photon，或服务器端代理 Nominatim 加缓存（单用户量极小，署名即合规） | **体验会降级**，MapKit 的联想明显更聪明。先用自己数据里的地名兜底 |
| `MKDirections` 驾车路线 | 自托管 OSRM（car profile，OSM extract，和数据管线同源）。`alternatives=true` 直接给备选路线 | 几何是 polyline6，解出来喂给 `route.js`，投影逻辑原样可用 |
| `CLGeocoder` 反查省/州名 | 不需要了：`manifest.json` 里已有各地区简化边界，点在多边形内判断 | 比 V2 更干净，纯本地 |
| `MKMapItem` 跳原生地图 | Tesla Fleet API，见下面第 5 节 | |

## 3. 车机实测前提

以下来自 tesla-video-streamer 的 featuretest 在真车上跑出来的日志，不是推测：

- **定位**：行驶中 ±1~3 m，带 altitude / speed / heading，`watchPosition` 约 10 Hz。比 iPhone 还好用，"圆心跟着我往前推"和"前方 xx km"都能做
- **`position.timestamp` 是坏的**（车机时钟不对，算出来的 age 是 1.7×10¹² ms）。判断定位新鲜度只能用自己收到的时刻，不能用 `timestamp`
- **WebGL2** 正常（AMD Vega / ANGLE，max texture 16384），矢量瓦片没问题。WebGPU 拿不到 adapter，不要用
- **屏幕** 804×638 CSS px，dpr 1.96，横屏。触摸目标 ≥44 px，没有 hover
- 引擎特性到 Chrome 140 全齐，**现代 JS/CSS 随便用**（tesla-video-streamer 那条 "ES5-ish, no build step" 是为 libav/WASM 播放器定的，不适用于这里）
- 缺 `navigator.share`、Magnetometer、蓝牙、NFC

## 4. 功能范围

- **附近模式**：V1 的全部功能（四类地点、圆心跟地图中心、半径档位、距离排序列表、分类开关、子过滤、营业状态、无名厕所的位置名、详情卡片）
- **路线模式**：V2 的 3a / 3b / 3c（目的地搜索、圆心沿路线拖动、滑条、前方最近一键跳转、备选路线、覆盖范围提示）
- "关于"页照旧注明数据来源（OSM ODbL 等授权要求），加上 Protomaps 和 OSRM 的署名
- 布局按 804×638 横屏重做。tesla-video-streamer 的 touchtest 已在真车上验过悬浮控件吸附、长按、行滑动、搜索 pill 配车机键盘，那套手势和 CSS 直接抄

## 5. 导航交接：Tesla Fleet API

车机浏览器点链接只会在浏览器里开网页，交不到车机原生导航手里。所以详情卡片的"导航"按钮走 [Fleet API](https://developer.tesla.com) 的 `navigation_request`，把目的地直接推给车机原生导航。

- 服务器（见第 6 节）保管 OAuth token 并定期刷新；这是 `data/` 之外第一份真正的密钥状态，和 `.env` 一起管，不进仓库
- **UI 必须可降级**：按钮旁边照样显示地址和坐标。推送失败、token 过期、车机在睡觉，都退回"自己手输进车机导航"，不是死路
- 做之前要确认
  - 车型和固件是否必须走 **Vehicle Command Protocol**（签名命令）而不是 REST。如果是，服务器要多跑一个 `tesla-http-proxy`，并把公钥放在 `https://<域名>/.well-known/appspecific/com.tesla.3p.public-key.pem` —— 正好托管选了家里服务器，公开域名顺带就有
  - **计费**：Tesla 对 Fleet API 按量计费，有免费额度。单用户一天几次 `navigation_request` 大概在额度内，但要先查当前政策
  - 注册第三方应用的流程能不能走通（要域名、要 client_id/secret）
  - 区域 base URL（北美是 `fleet-api.prd.na.vn.cloud.tesla.com`）
- 如果注册走不通或收费不合理，就停在"显示地址和坐标手输"，功能上不致命

## 6. 托管：蹭家里服务器

复用 tesla-video-streamer 那台机器的 Caddy + Cloudflare Tunnel + PIN 登录，**但不合仓**：

- Caddy 站点块里加一段指向本仓库的 `web/`，`forward_auth` 到同一个 FastAPI，PIN 复用
- PMTiles 放服务器上，Caddy `file_server` 直接服务（Range 原生支持）
- OSRM 一个独立 systemd unit，归本仓库的 `deploy/`。取 OSM extract 和预处理的脚本也放那儿
- 代价：车机在外面要通过 Cloudflare Tunnel 回家，**家里断网或服务器挂了地图就没了**。那台机器已经有 watchdog
- 另一条没选的路：全静态（GitHub Pages 发页面 + Cloudflare R2 放 PMTiles + OpenRouteService 免费 key 算路线），零服务器、车里任何地方都能开，但要暴露一个 key。如果家里服务器的可用性成了实际痛点，这是退路

## V3 不做

离线和瓦片预取（归 iOS 版）、Service Worker、法语界面、油价（只在 iOS 版做，见下面「油价」一节）、DriveBC 实时路况（见下面「候选数据源」）、偏离路线自动重新规划。

---

# 油价（iOS 版已实现 A → C；B 未做）

用 **GasBuddy** 逆向出来的 GraphQL 接口拿按站的油价，显示在现有的 MapKit 地图上，**只做 iOS 版**。没有任何合规版本，是明知的选择，理由和代价记在下面。

最早定的是 Google Places API 的 `fuelOptions`，后来放弃：Google Maps Platform 必须绑定开了结算的账号（即信用卡），免费额度内也一样，这是硬门槛；另外它的条款 (e) 不许在非 Google 地图上显示。评估记录留在下面「评估过但没选的源」。

## 选定方案

- 接口：`https://www.gasbuddy.com/graphql`，协议照抄 [py-gasbuddy](https://github.com/firstof9/py-gasbuddy)（MIT，在维护，背后是 Home Assistant 的 ha-gasbuddy）。按圆心查用 `locationBySearchTerm(lat, lng)` 的 `stations`（一页约 20 个站，带 cursor；只取第 1 页）
- 每次请求要带 `gbcsrf` 头，token 只存在于 `gasbuddy.com/home` 的 HTML 里（`window.gbcsrf = "..."`），而该页有 Cloudflare bot 检测。**2026-11 实测：家庭 IP 上 curl 直接拿到 403**
- 字段：每个油种（`regular_gas` / `midgrade_gas` / `premium_gas` / `diesel` / `e85` / `unl88`）一条，`credit` 和 `cash` 分开，各带 `price`、`postedTime`（**真正的用户上报时刻**）和上报人昵称；`priceUnit` 加拿大是 `cents_per_liter`，美国是每加仑美元
- 另外给每个站的名称、品牌、地址、营业时间（`hours`、`openStatus`）、设施（`amenities`）

## GB 请求怎么发：运行时降级链

三条路径都写进 App，按顺序试：

| | 路径 | 说明 |
|---|---|---|
| A | App 里隐藏的 `WKWebView` | 加载 `/home`（真 WebKit 引擎，Cloudflare 的 JS 挑战一般自动通过），再用 `evaluateJavaScript` 在页面里 `fetch('/graphql')`。同源请求，cookie 和 `window.gbcsrf` 都是现成的 |
| C | 直接 `URLSession` | Apple 的 TLS 指纹和 Safari 一样，但请求头顺序不同，大概率和 curl 一样 403。便宜，放着 |
| B | 家里服务器代理 | 见下面「B：家里服务器」 |

- 从**上次成功的那条**开始试；失败（403、拿不到 token、Turnstile、8 秒超时）立刻试下一条
- **429 例外**：Cloudflare 的限速按 IP 计，C 和 A 是同一个 IP，换 C 没用 —— 跳过 C 直接试 B（手机在蜂窝网络时 B 走家里的 IP，额度独立）；B 也 429 或不可用就整体暂停，见「请求时机」
- 成功的路径记住 6 小时，过期后重新从 A 开始试，A 恢复了能自动切回来
- 三条都失败：这次不显示价格，价格行不报错
- 要手动点的 Turnstile：**开车时绝不自动弹出 webview**，直接降级。设置页有「修复 GasBuddy」按钮，点了才把 webview 显示出来手动过，cookie 留在 WKWebView 的数据存储里
- 关于页显示「GasBuddy via WebView / Direct / Home server · 最后成功 10 分钟前」

### B：家里服务器（mintbox2）

- `server/gasbuddy/`：很小的 Python 服务，直接用 py-gasbuddy 库，`solver_url` 指向本机的 FlareSolverr（docker，只听 `127.0.0.1:8191`）。自己几乎不写 GB 协议代码，GB 改版就跟着升级 py-gasbuddy
- 只有一个接口 `GET /gb/prices?lat=&lng=`，返回的 JSON 和 A/C 解码后的形状一样，App 共用一个解码器。监听 `8766`
- **只代理 GB**，没有任何 key 经过它
- 部署脚本和 systemd unit 放本仓库 `deploy/`，**不碰 web_video_tesla**（它的 Caddy 占着 80/443、PIN 登录挡着非浏览器请求；它的 Cloudflare Tunnel 目前没启用）
- 上线顺序：先上 A → C；B 的服务端写好、本机测通，等下面的「对外方式」定了，App 里填一个地址即可启用

**对外方式：待定。** 候选：

| 方案 | 优点 | 代价 |
|---|---|---|
| Tailscale | 没有公网入口，攻击面最小；不要域名、不要 Caddy、不要共享密钥（tailnet 就是鉴权） | iPhone 要挂 Tailscale VPN（可开按需连接）。**顾虑**：以前装过之后公司 VPN 上不了网，而 mintbox2 也是在家工作的电脑 |
| 独立的 Cloudflare Tunnel | trip 自己一个 `cloudflared` 实例、自己的子域名，直连 `127.0.0.1:8766`，和 tesla 互不相干 | 要有 Cloudflare 上的域名；公网可达，必须加共享密钥鉴权（密钥放 `.env`，App 里写死，不进仓库） |
| 路由器端口转发 | 最简单 | 暴露家里 IP，不选 |

Tailscale 和公司 VPN 冲突通常来自 MagicDNS 改系统 DNS，或 `100.64.0.0/10` 的路由和公司 VPN 撞车。缓解办法：**Tailscale 跑在 docker 容器里、用户态网络（`TS_USERSPACE=true`）**，只有那个容器进 tailnet，宿主机的路由和 DNS 完全不动。也可以宿主机装但 `--accept-dns=false --accept-routes=false`、不用 exit node，但隔离不如容器彻底。

## 站点匹配

- GB 的站挂到 OSM 的加油站上：先比规范化地址（门牌号 + 街名），比不上再用 ≤ 100 m 且品牌相同，再比不上，≤ 30 m 不管品牌（OSM 很多站没有品牌，或者名字就叫「Gas Station」）。一个 OSM 点只给最近的那个 GB 站。挂上的，价格显示在 OSM 点上，OSM 的柴油、厕所等字段照用
- **GB 有、OSM 没有的站**：用 GB 的坐标画成临时点（**空心**的加油泵图标 `fuelpump`，OSM 点是实心的；来源写「GasBuddy (live, not in OpenStreetMap)」），列表里正常参与排序，路线模式里直接投影到路线上算「前方 xx km」；即使没有近期价格也显示（说明 OSM 漏了它）。离开搜索圆就不显示；只在内存里，App 重启就没了
  - 详情卡片用 GB 的名称、品牌、地址、营业时间、设施；导航按 GB 坐标照常跳转
  - 「加油站」分类开关照常管它；Open now 用 GB 的营业状态，没有就当未知、保留
- 没网时只有 OSM 点，价格行显示「需要联网」
- 阈值按验证脚本的实测匹配距离再调

## 请求时机

- 附近模式和路线模式一样：**松手**（地图、拖柄或滑条）**并且圆心移动超过阈值**才触发，不跟着 `regionDidChange` 调 —— GB 没有配额，但请求越密越容易被 Cloudflare 盯上
- **每次触发只取 1 页**（约 20 个站，基本是离圆心最近的）。半径大时外圈没有价格，打开详情卡片时补查
- **客户端限速**：所有 GB 请求合计**每分钟最多 6 个、两次之间至少隔 3 秒**（实测每 5 秒一个连续 5 分钟没事，取一半；被封的两次都是连发），超出的不排队，等到允许时只发最新圆心的那一个
- **收到 429**：按 `retry-after`（实测 600 秒）暂停**所有** GB 请求；列表顶上一行小字「Gas prices paused · back in 8 min」，已有的价格照常显示
- 打开详情卡片时，这个站还没价格，就以它为圆心补查一次（300 m 内 15 分钟里查过就不查）。OSM 点没有 GB 的 id，所以不用 `station(id)`
- 「松手」的实现：圆心停住 1 秒才发（地图的 `regionDidChange` 本身就是松手后才回调；拖柄和滑条拖动时圆心一直在变，等停住）
- 只在内存里，**不落盘**；同一圆心附近 15 分钟内不重复请求，回到前台时到期的重新查。拿到过的价格整个会话都显示（带年龄）：油价几小时就变，离线显示旧价没意义

## 显示

- 「我的油种」在 About 页顶上的 **Settings** 里选，默认 Regular，可选 Mid-grade / Premium / Diesel / E85，记住选择。地图和列表只显示这一种，详情卡片显示全部
- **地图上直接显示价格**：有价格的加油站，marker 下面的标签从站名换成价格（「185.9¢」，超过 24 小时加年龄「185.9¢ · 2d」），始终显示（`titleVisibility = .visible`）；没价格的照旧显示站名。聚合（cluster）里的点不显示
- 单位按当地习惯，不换算：BC「178.9¢/L」，WA「$4.29/gal」
- 时间用 `credit.postedTime`；`cash` 只在和 credit 不同时作为小字显示（加拿大基本只有一个价格，很少出现）
- **始终显示年龄**：「178.9¢/L · 2h ago」。`postedTime` 是上报时刻，不是此刻泵上的价格（GasBuddy 自己说一个站一天能改三次价）；别把自己的请求时间当成观测时间。超过 24 小时变灰，超过 7 天显示「No recent price」
- 每行不写来源、不写上报人；关于页的数据来源加 GasBuddy，注明是非官方接口
- 列表照旧按距离（路线模式按沿路先后）排序，这一版**不做按价格排序**；「下一个加油站」跳转不看价格

## 明知违反的条款

GasBuddy 使用条款：B（系统性下载建库）、D、F（规避技术措施 —— 绕 Cloudflare）、H（自动脚本抓取）全踩，**不存在任何合规版本**，也和本项目对 ODbL / OGL-BC 署名的讲究不自洽。个人项目、单用户、按需查询、不建库、不转售、不再分发；后果是 GB 封 IP 或改接口，最坏就是没有价格，App 其他功能不受影响。

**持续维护成本**：Cloudflare 封锁在 ha-gasbuddy 的 issue 里反复出现（2025-05、2025-12、2026-02）。降级链和「修复 GasBuddy」按钮就是为这个准备的；py-gasbuddy 的更新是风向标。

## 工程后果

- **油价是 Trip 的第一个在线功能。** 价格不进 `regions/<id>.json`、不走 Actions 管线（数据中心 IP 被 Cloudflare 拦得更狠，且只能做日快照）。离线时 Trip 依然完整可用，只是没有价格
- GB 会拿到搜索圆心的位置，接受

## 网页版（V3）

继续不做油价。Google 那条条款障碍已经不存在了，但网页版要拿 GB 只能走 B（浏览器跨域拿不到 GB），又多一条对家里服务器的依赖。以后想做再单独讨论。

## 评估过但没选的源

| 源 | 能拿到什么 | 为什么没选 |
|---|---|---|
| **Google Places API (New)** `places:searchNearby` + `places.fuelOptions` | 每油种一条 `price`（加拿大每升）和 `updateTime`；来源是 **OPIS**（道琼斯旗下），不含普通用户上报，加油站可通过 Business Profile 自己发布 | **必须绑卡**（Maps Platform 项目必须关联开了结算的账号，免费额度内也一样）。另外：属于 Enterprise + Atmosphere 档（Nearby Search 每月免费 1,000 次、超出 $40/1,000）；条款 3.2.3 (e) 不许在非 Google 地图上显示、(b) 不许缓存、(f) 不许用于车载设备；一次最多 20 个地点 |
| **Cardog**（cardog.app，加拿大商业 API） | `/v2/fuel/stations?lat&lng&radius_km&sort=price`，按站挂牌价（加元分/升）带 `postedAt`，响应带 `asOf`；另有省级和 FSA 级的日度中位数与分位 | **唯一真正拿到数据使用权的路**（付费客户）。但「当前价」定义为该油种最新且不超过 7 天 —— 日级甚至更旧。免费 50 次/月，付费约 $23–30/月起。数据来源未披露。**如果哪天 GB 彻底封死，这是退路** |
| **OPIS 直接授权** | Google 和 Waze 的上游，质量天花板 | 企业级卖法，单人项目拿不到 |
| **NRCan 交通燃油价格** | 每周、按城市平均 | 免费官方、署名即可，但做不了单站价。可以当「BC 本周均价和趋势」的背景信息 |
| **批发 rack 挂牌 + BC 燃油税率** | 批发涨跌 → 「今天该不该加油」 | 免费公开，但推不出单站价；Petro-Canada 的 rack 页面拦自动抓取（403），不是可靠接口 |

另外记一笔：Waze（同属 Google）让用户手改油价，但 2026-05 的公告说 Waze 正在接入「与 Google Maps 目前使用的是同一条」升级版 OPIS feed。

## 动手顺序

1. **验证脚本（写任何 App 代码之前）**：scratchpad 里的 venv，用 Playwright 驱动本机已装的 Google Chrome（有界面模式，headless 容易被识别），打开 `/home` 后在页面里 `fetch('/graphql')` —— 原理和 A 一样，顺便当 A 的桌面预演。查温哥华、Hope、Merritt、Kamloops、Clearwater、Costco Burnaby：每处返回的站数、`postedTime` 年龄分布、和 OSM 的匹配距离
   - 温哥华 24 小时内有价格的站不到一半 → 停下来重新讨论
   - 只是非都市区差 → 照样做，结果记在这里（以后在山里看到「No recent price」是预期内的）
   - 仓库店（Costco 等）有没有价格也记一笔
   - **结果（2026-11-02，mintbox2 家庭 IP，Playwright + 有界面的 Chrome）**：见下面「验证结果」
2. 真机上做 A 的最小原型，验证 WKWebView 能否稳定拿到 token
3. App 实现；解码器和匹配逻辑的用例加进 [scripts/test-swift.sh](scripts/test-swift.sh)
4. B 的服务端，本机测通

## 验证结果（2026-11-02）

查询点周围去重后的站数，「新鲜」指 Regular 的 credit 价 `postedTime` 在 24 小时内；「OSM 距离」是 GB 坐标到最近 OSM 加油站的距离：

| 点 | 站数 | ≤24h | ≤7 天 | OSM ≤50 m | OSM ≤100 m | 门牌+街名能对上 |
|---|---|---|---|---|---|---|
| Vancouver downtown | 60 | 57 | 57 | 59 | 59 | 34 |
| Burnaby | 60 | 59 | 59 | 60 | 60 | 29 |
| Hope | 14 | 9 | 13 | 12 | 13 | 8 |
| Merritt | 13 | 9 | 11 | 11 | 11 | 11 |
| Kamloops | 39 | 33 | 34 | 28 | 35 | 16 |
| Clearwater | 4 | 2 | 2 | 4 | 4 | 3 |

- **温哥华过关**（95% 在 24 小时内，大多数 1–4 小时）。非都市区够用：Hope / Merritt 约 2/3 在 24 小时内，小镇和杂货铺式的站（Quilchena、Vavenby）没有价格
- **加拿大确实只有一个价格**：`cash` 全是空的。单位全是 `cents_per_liter` / `CAD`
- **匹配**：大都市 ≤50 m 就几乎全中；Kamloops 有几个 76–218 m 的（Canadian Tire、商业区里的站），100 m 阈值合适，再远的当 GB-only 临时点。门牌+街名只能对上约一半（OSM 缺地址，或写法不同，如「Old Hope Princeton Way / Hwy」），所以地址只能当优先信号，距离+品牌是主力
- **返回结果的坑**：不是严格按距离排序，会混进 20 km 外的站；翻页之间有重复（要按 `id` 去重）；`price: 0` 表示没有价格（不是零元）；圆心落在城市边缘时 3 页（60 个站）只覆盖约 6–7 km —— 大半径时列表外圈不会有价格
- **仓库店**：Kamloops 的 Costco 有价格（0.7 小时前）。Burnaby 那个点 60 个结果里没有 Costco，按品牌补查时撞上了下一条，没查成
- **Cloudflare 会升级**：第一次会话静默通过，约 20 个请求后，几分钟内重开的会话直接被拦成 403「Verify you are human」（要手动点的 Turnstile）。Playwright 驱动的 Chrome 带自动化特征，App 里的 WKWebView 没有，未必一样；但说明降级链和「修复 GasBuddy」按钮是必需的，请求节奏也要克制

**手机实测（2026-11-02，iPhone，原型 probe）**

- WKWebView（路径 A）**一次 Turnstile 都没遇到**，拿 token 和查询都很顺；单次查询（含 1–3 页）平均不到 1 秒
- 真正的瓶颈是 **Cloudflare 限速**：HTTP 429，`server=cloudflare`，`retry-after=600`（罚 10 分钟），**按 IP**（清 cookie 无效，切到蜂窝立刻恢复；家里 Wi-Fi 和 mintbox2 共用一个公网 IP，桌面上的测试也算在同一个额度里）
- 桌面上 Playwright 驱动的 Chrome 第二次起就**无限循环 Turnstile**（点了又来），说明 Cloudflare 认的是自动化特征而不是 IP —— 桌面自动化测不了，限速只能在手机上测；也说明 B 用的 FlareSolverr（同样是自动化 Chrome）未必过得去，做 B 时要先验证
- 1 分钟内 5 次查询 × 最多 3 页 ≈ 15 个 GraphQL 请求就触发；桌面上 15 个请求各隔 1.5–2 秒没触发。后来在手机上从慢往快测：每次 1 页，每 20 秒、10 秒、**5 秒一次各连续 5 分钟都没事**（每分钟 12 个）。被封的两次都是短时间连发，所以客户端除了每分钟上限还要求两次之间隔 3 秒

---

# 候选数据源：DriveBC / Open511（只记录，V2 不做）

BC 省交通厅（MoTI）两套公开接口，内容比现在用的静态 POI 丰富很多，是 road trip 场景里最直接的体验提升。先记在这里，等 V2 的路线模式稳定后再评估。

## 能拿到什么

| 来源 | 内容 |
|---|---|
| Open511（`api.open511.gov.bc.ca/events`）| 实时路况事件：施工、事故、特殊活动、天气状况。每条带 `event_type`、`severity`、`geography`（点或线）、`roads`（公路名、方向、起止、`state` 如 CLOSED / SOME_LANES_CLOSED、延误时间）、`schedules`（生效时段）、`updated` |
| DriveBC 摄像头 | 全省几百个公路摄像头的列表（id、名称、说明、公路编号、经纬度）+ 定时更新的截图 URL；还有朝向和拍摄时间 |
| DriveBC 其他 | 公路气象站（路面温度、路面状况）、内陆渡轮班次和等待、边境口岸等待时间 |

## 可能怎么用

- **路线模式叠加路况**：选中的路线上标出前方的封路和施工，列表里的"前方 xx km"旁边提示"前方 12 km 有单线通行，延误约 20 分钟"
- **第五个类别：摄像头**：当成一类地点显示在地图和列表里，详情卡片直接贴最新截图 —— 冬天翻 Coquihalla 之前看一眼路面，比任何文字都有用
- **休息区详情里嵌附近摄像头**，以及休息区是否因施工关闭
- **出发前检查**：路线模式算完路线后，顶上一条横幅汇总整条路线的封路情况
- **冬季轮胎/链条要求**：Open511 的 weather condition 事件里常带这类信息

## 做之前要先确认

- 授权：MoTI 数据是 Open Government Licence – British Columbia，需要署名；摄像头图片能不能在 App 里直接显示要单独确认（DriveBC 有自己的使用条款），必要时改成跳转网页
- 这是**实时**数据，和现在"GitHub Actions 定时生成 + App 下载"的静态模型不一样：要么 App 直接请求 MoTI 接口（需要处理没网、超时、速率限制），要么 Actions 高频重建（但几分钟级的更新不现实）。倾向前者，按路线的 bbox 查，结果只缓存几分钟
- 只覆盖 BC；WA 及以后的地区要各自找对应来源（WA 有 WSDOT API，同样有摄像头）
- 摄像头截图走 CDN，流量和耗电要测；列表里只显示缩略图，详情页才加载大图
- 事件的 `geography` 是经纬度，要和自己算出来的 `MKDirections` 路线做匹配（投影到折线、取沿线距离），和现在的"离路线多远"逻辑能复用
