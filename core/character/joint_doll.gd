# 关节人偶运行时：静态碎片 + 枢轴树 + 正弦驱动 + 弹簧次级动画
#
# 这一版对应参考视频《独立游戏开发日记 2：角色是怎么动起来的》的实际做法：
#   · "每块都是一张静止的图，钉在关节上"  -> 无动画帧、无蒙皮
#   · "腿按正弦波来回摆，两条腿正好相反"   -> 相位差 π
#   · "手跟腿反着摆"                       -> 同侧手臂取腿的反相
#   · "腿摆一个来回，身体颠两次"           -> 竖直位移取 2× 频率
#   · "正面看腿没法前后摆，改成左右交替抬脚" -> 按视图切换曲线类型
#   · "每个方向单独排一遍图层"             -> 逐方向 z 序
#   · "给披风挂一根看不见的弹簧"           -> SpringJoint（头发默认刚性，见 spring_on_hair）
#
# 与 Skeleton2D 方案的区别：这里根本不需要 Skeleton2D。
# 纯 cutout 的层级就是普通 Node2D 的父子关系，改 rotation 即可；
# Skeleton2D 只在需要 Polygon2D 蒙皮变形时才有价值，而本方案不需要变形。
#
# 为什么加了 @tool：节点树是**运行时用代码建的**（_build_tree），不加 @tool 时
# 编辑器里这个节点是空的 —— 打开 .tscn 只看到一个原点，什么都看不见。
# 加了之后编辑器里也会建一遍，并且画出枢轴/骨骼线、可以用检视面板上的
# preview_direction / preview_phase / preview_pose 直接摆姿势看效果。

@tool
class_name JointDoll
extends Node2D

signal view_changed(view: int)
## 编辑器里手动拖关节时发出（插件和姿势面板靠它同步）
signal editor_pose_changed

enum View { S, SW, W, NW, N }
const VIEW_NAMES := ["s", "sw", "w", "nw", "n"]
const ANCHOR := Vector2(128, 216)

## 方向 -> (视图, 是否镜像)。屏幕坐标系 y 向下：0=S 1=SW 2=W 3=NW 4=N 5=NE 6=E 7=SE
const DIR_TO_VIEW := [
	Vector2i(View.S, 0), Vector2i(View.SW, 0), Vector2i(View.W, 0),
	Vector2i(View.NW, 0), Vector2i(View.N, 0),
	Vector2i(View.NW, 1), Vector2i(View.W, 1), Vector2i(View.SW, 1),
]

## 枢轴表：[关节名, 父关节, 画布坐标]。顺序即前序，父必须在子之前。
## 与 tools/gen_joint_art.py 的 JOINTS 必须一致 —— 美术的球关节画在这里
##
## 肩枢轴 108/148 是**故意收进躯干轮廓（128±16）之内 4px** 的。
## 放在轮廓外（原来的 104/152）时，肩球球心到桶边有 8px，画面里只能相切：
## 静止就有一条 1~2px 背景缝，摆臂 ±20° 后张到 3px，看上去胳膊是贴在身体外面的。
## 挪进 4px 后球心到桶边只剩 4px，8.5 半径的肩球压进去 4~6px，且绕枢轴怎么转都不变。
## 肘一起平移，上臂斜度不变；只挪肩会让腋下裂得更开。
## 改动这里必须同步 tools/gen_joint_art.py 与 tools/check_joint_gap.py（后者拿它算旋转中心）。
const JOINTS := [
	["hip",        "",           Vector2(128, 146)],
	["chest",      "hip",        Vector2(128, 110)],
	["head",       "chest",      Vector2(128, 100)],
	["shoulder_l", "chest",      Vector2(108, 108)],
	["elbow_l",    "shoulder_l", Vector2(102, 130)],
	["shoulder_r", "chest",      Vector2(148, 108)],
	["elbow_r",    "shoulder_r", Vector2(154, 130)],
	["hip_l",      "hip",        Vector2(120, 152)],
	["knee_l",     "hip_l",      Vector2(119, 182)],
	["hip_r",      "hip",        Vector2(136, 152)],
	["knee_r",     "hip_r",      Vector2(137, 182)],
]

## 槽位 -> 关节（"钉在哪个关节上"）
##
## 这张表必须和 SLOT_Z 一一对应。缺一个键的槽位以前会静默落到 hip，
## 表现是「戴了个耳环，耳环长在胯上」—— 已经改成缺键直接报错跳过。
##
## 上半身两块（body/clothes）钉在 chest 而不是 hip：躯干要能跟着胸一起前倾，
## 钉在 hip 的话攻击时手臂和头动了、身体还杵着，像雕塑上装了假手。
const SLOT_JOINT := {
	&"body": "chest", &"clothes": "chest",
	&"tail": "hip",
	&"cape": "chest", &"wing": "chest", &"shoulder": "chest",
	&"head": "head", &"hair_front": "head", &"hair_back": "head", &"hat": "head",
	&"ear": "head", &"face": "head",
	&"arm_l": "shoulder_l", &"fore_l": "elbow_l", &"glove_l": "elbow_l",
	&"arm_r": "shoulder_r", &"fore_r": "elbow_r", &"glove_r": "elbow_r",
	&"leg_l": "hip_l", &"shin_l": "knee_l", &"shoes_l": "knee_l",
	&"leg_r": "hip_r", &"shin_r": "knee_r", &"shoes_r": "knee_r",
	# 武器挂在右手前臂末端：fore_r 和 weapon 绕同一个枢轴转，位置恒定不变，
	# 所以「握持」是几何自然的结果，不需要每帧重算手的位置
	&"weapon": "elbow_r", &"offhand": "elbow_l",
}

## 槽位 -> z。叠加顺序和 17 槽位纸娃娃完全一致
## 注意：四肢不在这里定最终 z，见 LIMB_Z —— 它们要按"近侧/远侧"分两套
const SLOT_Z := {
	&"hair_back": 0, &"cape": 2, &"wing": 4, &"tail": 5,
	&"leg_r": 6, &"shin_r": 7, &"arm_r": 8, &"fore_r": 9,
	&"leg_l": 6, &"shin_l": 7,
	&"body": 10, &"clothes": 20,
	&"shoes_l": 9, &"shoes_r": 9,
	&"arm_l": 13, &"fore_l": 14,
	&"head": 30, &"ear": 31, &"face": 32, &"hair_front": 34, &"hat": 36,
	# 护肩原来 40：比 head(30) 还高，一转身会盖住脸。护肩在肩线，永远不该压过头
	&"shoulder": 26,
	&"glove_l": 42, &"glove_r": 42,
	&"offhand": 48, &"weapon": 50, &"summon": 60,
}

## 四肢的 z 必须分「近侧 / 远侧」两套。
##
## 这是八向里最容易漏、也最难看的一处：正面 3/4 和背面 3/4 的远近正好相反。
## 镜头看到的是角色哪一侧，决定了"离镜头近的那条胳膊"画在躯干前面还是后面。
## 只用一套固定 z（我们之前那样），转身到背面 3/4 时近侧胳膊会钻进身体里，
## 走路时在躯干上忽隐忽现。
##
## 镜像是屏幕左右翻转，前后深度不变 —— 所以远近按「视图」判定，不按「方向」判定。
const LIMB_Z := {
	&"arm_l":   {"near": 13, "far": 8},
	&"fore_l":  {"near": 14, "far": 9},
	&"glove_l": {"near": 14, "far": 9},
	&"arm_r":   {"near": 13, "far": 8},
	&"fore_r":  {"near": 14, "far": 9},
	&"glove_r": {"near": 14, "far": 9},
	&"leg_l":   {"near": 8,  "far": 6},
	&"shin_l":  {"near": 9,  "far": 7},
	&"shoes_l": {"near": 9,  "far": 7},
	&"leg_r":   {"near": 8,  "far": 6},
	&"shin_r":  {"near": 9,  "far": 7},
	&"shoes_r": {"near": 9,  "far": 7},
}

## 视图 -> 贴图上哪一侧离镜头近。**这里的左右是贴图坐标，不是屏幕坐标。**
## 空串 = 正/背面，左右等距，两侧取同一套 z（见 "对称视图"）。
##
## 推导：角色朝 -x，绕竖直轴转 θ（0=正面朝镜头，90=侧面，180=背面），
## 贴图 x<128 那侧（记 "l"）的方向是 (cosθ, sinθ)：θ=0 时在屏幕右、
## z=sinθ 朝着镜头走。所以
##   θ=45  (sw) → "l" 在屏幕右（cos45>0）且更远   → 近侧是 "r"
##   θ=90  (w)  → "l" 正好正对镜头，投影到中线     → 近侧仍是 "r"（同一只手）
##   θ=135 (nw) → "l" 已转到屏幕左（cos135<0）     → 近侧翻成 "l"  ← 曾经错写成 "r"
##
## NW 这一格是八向里唯一"近侧在贴图左边"的视图。写成 "r" 的后果不是抽象的：
## 美术把 "r" 画暗、画小、往里收（far_limb），z 表却把 "r" 抬到躯干前面 ——
## 于是暗的、缩小的那条胳膊压在身体上，亮的那条沉到身后，
## 反过来读就是"近侧的肩膀跑到背后去了"。
##
## 对称视图（正/背）不能靠"猜左边还是右边"来分近远：sinθ=0，两侧到镜头等距，
## 硬分一个近侧会让其中一条胳膊的肩球被躯干切掉半个，正面看着一边大一边小。
const NEAR_SIDE := {
	View.S: "", View.SW: "r", View.W: "r", View.NW: "l", View.N: "",
}

## 逐方向 z 覆盖表：参考视频原话「每个方向，都单独排一遍图层」
## 典型症状：背面朝向时披风被身体挡住，整个人像丢了披风
## 3=NW 4=N 5=NE 都是背面朝向
const BACK_VIEW_DIRS := [3, 4, 5]
const Z_ON_BACK := {
	&"cape": 22,        # 披风盖住身体（身体 10、衣服 20）
	&"hair_back": 31,   # 后发盖住后脑（head 30）——背面看到的是一头头发，不是木头
	&"hair_front": 0,   # 刘海在背面视图里必须沉到最底：万一带了 nw 图，也不许糊在后脑上
	&"face": 0,         # 五官贴片同理，背面不许出现
	&"wing": 16,        # 翅膀正面看是在身后（4），从背后看必须盖住身体
	&"tail": 16,        # 尾巴同理：正面沉在腿后（5），背后要盖住腿
	&"offhand": 8,
	# 肩球跟着手臂一起收进披风后面（21 < 披风 22）。
	# 不跟的话：手臂藏进布里了，两颗金球还浮在红布上，像钉上去的两枚扣子
	&"shoulder": 21,
	# 拿剑的手（weapon 挂在 elbow_r 上）也收进披风后面 —— 用户拍板 v3。
	# 这条也反转过：v2 之前 weapon 故意留在布外（50），背面只剩一把剑浮在红布上，
	# 和已经藏进布里的手臂脱节，看起来像剑凭空粘在披风上。现在跟着手一起沉到 21
	# （仍 > 躯干 10：是被布盖住，不是被身体吞掉）。SW/W/S 是正面朝向，不走这张表，
	# 剑仍画在最前面。要改回「布外持剑」：删掉这一行 + 把 layer_rules.json
	# 里 nw/n 的 weapon 格调回 50。
	&"weapon": 21,
}

## 背面朝向时，**两只手臂连肩球一起收进披风后面**。
##
## 这条规则反转过一次，把两个版本都记下来，免得以后又改回去：
##
## · v1（手臂在布外）：只把「近侧」抬到 24，远侧留在 LIMB_Z 的 8 ——
##   NW 的披风覆盖 x 119–144，远侧 arm_r 在 138–155，内半边被布吃掉，
##   且随摆臂周期性地钻进钻出，只剩一把剑浮着。于是改成双臂 24/23 压过披风。
## · v2（现在的样子，用户拍板）：披风是一整块裹住后背的布，胳膊垂在身侧
##   本来就该被布挡住 —— 双臂+肩球一起压到 21/20（仍在躯干 10 之前），
##   披风 22 盖在最上面。SW 同理：远臂整条沉到披风(2)之下。
##   副作用想清楚才用的：背面视图里手臂完全看不见（被布盖住）。
##   手里的武器起初也留在布外（weapon 50）——后来 v3 又反转：剑跟着拿剑的
##   手一起收进披风后面（见 Z_ON_BACK 的 weapon 注释），否则布上会浮着一把
##   凭空出现的剑。
const ARM_Z_ON_BACK := {
	&"arm_l":   {"near": 21, "far": 20},
	&"arm_r":   {"near": 21, "far": 20},
	&"fore_l":  {"near": 21, "far": 20},
	&"fore_r":  {"near": 21, "far": 20},
	&"glove_l": {"near": 21, "far": 20},
	&"glove_r": {"near": 21, "far": 20},
	# shoulder 不在这里：它不分左右两条，不走 LIMB_Z 的近/远分支，
	# 查不到。它进 Z_ON_BACK（背面统一 21），见下
}

## 挂弹簧的槽位。
## 只放披风：二次复核视频逐帧后确认，画面里大幅甩动的是披风，
## 头发（编辫/整片）几乎不动，最多随头整体旋转。
## 需要"后天再接一根马尾"时，把 spring_on_hair 打开即可。
const SPRING_SLOTS := [&"cape"]
const SPRING_SLOT_HAIR := [&"hair_back"]

## 视图 -> 弹簧增益。
##
## 弹簧是「屏幕 x 方向」的单摆：它只会左右摆。可角色朝镜头走时（S/N），
## 披风真正在动的是**前后（景深）**，屏幕上几乎不该左右甩。
## 不乘这档增益，正面走路时披风会像被侧风刮到一样左右乱扑 —— 比不动更假。
const SPRING_GAIN := {
	View.S: 0.25, View.SW: 0.70, View.W: 1.00, View.NW: 0.70, View.N: 0.25,
}

## 视图 -> 步行参数。
##   mode 0 = 侧向：腿前后摆（角度制），膝盖跟着摆
##   mode 1 = 正/背面：腿**竖直**抬起（lift，px），一个角度都不加
## leg/arm 是摆幅(°)，bob 是竖直颠簸(px)，knee 是弯膝(°)，lift 是抬脚高度(px)
##
## mode 1 的 leg/knee 必须是 0：正面走路时腿的前后位移投影到屏幕上是**缩短**，
## 不是旋转。给角度等于让小腿在画面里转过去 —— 脚就甩到腿的左边/右边了（见 _pose_walk）。
##
## arm 曾经是 W 18 / N 4：W 的剑（挂在前臂末端）会从脸前一路扫到头顶，
## N 里剑尖也探到头顶旁 —— 用户反馈「手臂高于肩膀了」。
## 武器跟着前臂一起转，摆臂峰值直接决定剑尖划过的弧线，所以这两个方向压小：
##   W 12 —— 和 3/4 视图（SW/NW 13）同一档，侧身走路不再抡过肩线；
##   N  2 —— 背面手臂本来就藏在披风后，剑是唯一露出来的部分，只留一点呼吸感。
## 肘部常驻弯曲（度）。侧向走路时前臂永远朝身前折这么多，前摆时再叠摆幅的一半。
## 觉得弯得不够/太多，就调这一个数（14 弯得很含蓄，22 很明显）。
const ELBOW_REST_DEG := 20.0

const PROFILE := {
	View.S:  {"leg": 0.0,  "arm": 4.0,  "bob": 2.2, "knee": 0.0,  "lift": 7.0, "mode": 1},
	View.SW: {"leg": 19.0, "arm": 13.0, "bob": 2.5, "knee": 16.0, "lift": 0.0, "mode": 0},
	View.W:  {"leg": 26.0, "arm": 12.0, "bob": 3.2, "knee": 22.0, "lift": 0.0, "mode": 0},
	View.NW: {"leg": 19.0, "arm": 13.0, "bob": 2.5, "knee": 16.0, "lift": 0.0, "mode": 0},
	View.N:  {"leg": 0.0,  "arm": 2.0,  "bob": 2.2, "knee": 0.0,  "lift": 7.0, "mode": 1},
}

## ── 前后关系（z 序）的外部副本 ────────────────────────────────────────
##
## 上面那几张表（SLOT_Z / LIMB_Z / NEAR_SIDE / Z_ON_BACK / ARM_Z_ON_BACK）描述的是**规则**，
## 而真正决定"谁盖住谁"的是它们推导出来的 5 视图 × 26 槽位的结果矩阵。
## 想调前后关系却要同时改五张互相耦合的表，太容易改出一对互相矛盾的格子，
## 所以结果矩阵可以外置到 data/layer_rules.json：
##
##   tools/dump_layers.gd       把当前推导结果写成 JSON（基线）
##   tools/layer_designer.html  可视化编辑那张矩阵，导出 JSON
##   本文件                     启动时读 JSON；文件不在就退回推导
##
## 外置的只是**结果**不是规则：某视图某槽位缺键时仍按推导补上，
## 所以删掉几个格子不会让部件凭空消失。
const LAYER_RULES_PATH := "res://data/layer_rules.json"

## 视图名 -> {槽位: z}。空 = 没有外部矩阵，全部走推导
var layer_z: Dictionary = {}
## 摆动触发的动态层级（见 _apply_swing_z），默认空
var swing_rules: Array = []
var _z_static: Dictionary = {}      # 槽位 -> 静止 z，供摆动规则回退
var _swing_hot: Dictionary = {}     # 槽位 -> 摆动规则当前是否生效


@export var visual: CharacterVisual:
	set(v):
		visual = v
		if is_inside_tree():
			_rebuild_parts()
		if Engine.is_editor_hint():
			# 没有这句，场景面板上那个「缺 visual」的黄三角在补上 visual 之后也不消失
			update_configuration_warnings()

## 多只角色同屏时用它错开 z 区间：z_index = z_base + slot_z
@export var z_base: int = 0
## 弹簧总开关（对应视频里"弹簧 关 / 弹簧 开"的对比）
@export var spring_enabled: bool = true:
	set(v):
		spring_enabled = v
		for s in _springs.values():
			s.enabled = v

## 头发是否也挂弹簧。默认关闭。
## 复核视频逐帧后的结论：头发是钉死在头骨上的硬片，画面上几乎不动；
## 真正被甩出去又弹回来的是披风。想让"长马尾"单独甩就打开这里
## —— 只对 hair_back 生效，刘海（hair_front）永远是刚性的。
@export var spring_on_hair: bool = false:
	set(v):
		spring_on_hair = v
		if is_inside_tree():
			_rebuild_parts()

@export_group("步态")
## 一个完整步幅的时长（秒）。越小走得越快
@export var stride_time: float = 0.78
@export var spring_stiffness: float = 90.0
@export var spring_damping: float = 5.5
## 惯性增益：越大头发甩得越夸张
@export var spring_inertia: float = 0.035
## 空气阻力：行走时头发/披风持续后拖的幅度
@export var spring_drag: float = 0.10

@export_group("编辑器预览")
## 下面四个只在**编辑器**里生效（运行时被 is_editor_hint() 挡掉），
## 用来在不运行游戏的情况下摆姿势、看枢轴、看层级。
## 编辑器里不跑 _process：姿势由 preview_phase 一次性算出来，拖滑杆即时刷新。

## 方向 0-7（S/SW/W/NW/N/NE/E/SE）。改它等于运行时调 set_direction()
@export_range(0, 7) var preview_direction: int = 0:
	set(v):
		preview_direction = v
		if Engine.is_editor_hint() and is_node_ready():
			set_direction(v)

## 步幅相位 0-1。0.25 / 0.75 是两条腿张开最大的两个瞬间
@export_range(0.0, 1.0, 0.01) var preview_phase: float = 0.25:
	set(v):
		preview_phase = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 预览哪个动作
@export_enum("idle", "walk", "attack", "hurt") var preview_pose: String = "walk":
	set(v):
		preview_pose = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 画枢轴球 + 骨骼连线。把父节点拖进视口缩放时很有用
@export var show_rig: bool = true:
	set(v):
		show_rig = v
		if Engine.is_editor_hint():
			_queue_rig_redraw()

## 再叠一层关节名。11 个关节挤在 50px 宽的范围里，名字必然互相压 ——
## 默认关闭，要看名字时开它并把视图放大（滚轮）。左右两半各往两侧排、再按索引错开一行。
@export var show_rig_names: bool = false:
	set(v):
		show_rig_names = v
		if Engine.is_editor_hint():
			_queue_rig_redraw()

var view: View = View.S
var direction: int = 0
var action: StringName = &"idle"

var phase: float = 0.0            # 0..1 一个完整步幅
var _time: float = 0.0            # 通用计时，给 idle/attack/hurt 用
var _action_time: float = 0.0     # 当前非循环动作已播放时长

var _canvas: Node2D
var _joint_nodes: Dictionary = {}   # 关节名 -> Node2D
var _base_pos: Dictionary = {}      # 关节名 -> 静止局部坐标
var _sprites: Array[Sprite2D] = []
var _springs: Dictionary = {}       # 槽位 -> SpringJoint
var _rot: Dictionary = {}           # 本帧算出的关节旋转（弧度）
var _bob: float = 0.0               # 髋部竖直起伏（px）
var _lift_offsets: Dictionary = {}   # 抬脚时的关节竖直偏移（px）
var _rig_overlay: Node2D = null     # 编辑器专用：画枢轴/骨骼线的独立图层

## 编辑器里手动摆的姿势：关节名 -> 弧度。运行时恒为空。
## 程序化姿势（walk/idle/attack）照常算，这里手动改过的关节在 _apply_rot() 末尾覆盖上去 ——
## 这样「拖一下看看」和「滑杆一推整个姿势重算」不会互相擦掉。
var editor_pose: Dictionary = {}


## 编辑器里画骨骼线的图层。必须独立成节点：
## 部件精灵的 z_index 是 6~50（且 z_as_relative=false），人偶节点自己画的线 z_index 是 0，
## 直接在本节点 _draw() 里画会被所有部件盖住 —— 看起来"枢轴不见了"。
class RigOverlay:
	extends Node2D
	var doll: Node2D = null

	func _draw() -> void:
		if doll != null:
			doll.draw_rig(self)


func _ready() -> void:
	_build_tree()
	_rebuild_parts()
	if Engine.is_editor_hint():
		# 编辑器里不跑 _process，姿势一次性算出来
		set_direction(preview_direction)
		update_configuration_warnings()


## 编辑器里"没有东西可画"是最常见的一脸懵：给出明确原因
func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if visual == null:
		out.append(
			"visual 是空的 —— 这个节点不会画出任何部件。\n" +
			"要么在检视面板里指定一个 CharacterVisual 资源，" +
			"要么直接打开 demo/doll_preview.tscn（它会自动从 assets/parts 装配一份）。")
	return out


## 读外部前后关系表。文件不在 / 不合法 → 什么都不做，退回内置推导
func _load_layer_rules() -> void:
	layer_z.clear()
	swing_rules.clear()
	if not FileAccess.file_exists(LAYER_RULES_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYER_RULES_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("JointDoll: %s 解析失败，改用内置 z 表" % LAYER_RULES_PATH)
		return
	var root: Dictionary = parsed
	var zv: Variant = root.get("z", {})
	if typeof(zv) == TYPE_DICTIONARY:
		for vname in zv.keys():
			var row: Variant = zv[vname]
			if typeof(row) != TYPE_DICTIONARY:
				continue
			var one := {}
			for slot in row.keys():
				one[StringName(slot)] = int(row[slot])
			if not one.is_empty():
				layer_z[String(vname)] = one
	var sv: Variant = root.get("swing", [])
	if typeof(sv) == TYPE_ARRAY:
		for r in sv:
			if typeof(r) == TYPE_DICTIONARY and r.has("slot") and r.has("joint"):
				swing_rules.append(r)
			else:
				push_warning("JointDoll: swing 规则缺 slot/joint，已忽略：%s" % str(r))


# ---------------------------------------------------------------- 建树

func _build_tree() -> void:
	# 外部前后关系表在建树时读一次。放在这里而不是 _ready()，
	# 是为了让 tools/zdump.gd / gait_probe.gd 这类"手动建树"的脚本
	# 也走同一条路径 —— 否则工具校验的是内置表、游戏跑的是 JSON，两边悄悄分叉
	_load_layer_rules()
	# 画布原点 (0,0) 与骨架局部 1:1；整体再平移，让脚底锚点落在节点原点
	_canvas = Node2D.new()
	_canvas.name = "Canvas"
	_canvas.position = -ANCHOR
	add_child(_canvas)

	for entry in JOINTS:
		var jname: String = entry[0]
		var parent_name: String = entry[1]
		var g: Vector2 = entry[2]

		var n := Node2D.new()
		n.name = jname
		# 局部坐标 = 本关节画布坐标 - 父关节画布坐标
		var parent_g := Vector2.ZERO
		if parent_name != "":
			parent_g = _joint_canvas_pos(parent_name)
		n.position = g - parent_g
		n.set_meta(&"canvas_pos", g)

		var parent: Node = _canvas
		if parent_name != "":
			parent = _joint_nodes[parent_name]
		parent.add_child(n)
		_joint_nodes[jname] = n
		_base_pos[jname] = n.position
		_rot[jname] = 0.0

	# 编辑器专用图层：枢轴球 + 骨骼线 + 关节名。挂在 _canvas 下，跟着画布坐标走
	if Engine.is_editor_hint():
		var ov := RigOverlay.new()
		ov.name = "RigOverlay"
		ov.z_index = 4096            # 压过所有部件（最大 60）
		ov.z_as_relative = false
		ov.doll = self
		_canvas.add_child(ov)
		_rig_overlay = ov


## 编辑器里画骨架：关节球 + 父子连线 + 名字。
## 画在 canvas 坐标（未减 ANCHOR 之前的那套坐标），因为 overlay 是 _canvas 的子节点。
func draw_rig(ci: CanvasItem) -> void:
	if not show_rig:
		return
	var font := ThemeDB.fallback_font
	# 人偶在镜像视图里 scale.x = -1，字会跟着翻。这里反着缩一次把字扶正
	var sgn := -1.0 if scale.x < 0.0 else 1.0
	for i in JOINTS.size():
		var entry: Array = JOINTS[i]
		var jname: String = entry[0]
		var parent_name: String = entry[1]
		var p: Vector2 = entry[2]
		if parent_name != "":
			ci.draw_line(_joint_canvas_pos(parent_name), p, Color(0.10, 0.72, 0.95, 0.90), 1.5, true)
		ci.draw_circle(p, 3.5, Color(1.0, 0.30, 0.55, 0.95))
		ci.draw_arc(p, 7.0, 0.0, TAU, 20, Color(1.0, 0.30, 0.55, 0.50), 1.0, true)
		if not show_rig_names:
			continue
		# 左半边的字往左放、右半边的往右放（11 个关节挤在 50px 宽里，
		# 全往同一边长会连成一片），再按索引错开三行，避免同一侧的上下关节叠在一起
		var left_side: bool = p.x < ANCHOR.x
		var dx := -12.0 if left_side else 12.0
		var dy := -7.0 + float(i % 3) * 9.0
		ci.draw_set_transform(Vector2(sgn * (p.x + dx), p.y + dy), 0.0, Vector2(sgn, 1.0))
		ci.draw_string(font, Vector2.ZERO, jname,
			HORIZONTAL_ALIGNMENT_RIGHT if left_side != (sgn < 0.0) else HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11, Color(0.05, 0.42, 0.72))
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 脚底锚点：所有"画布坐标"都是相对它的
	var anchor := Vector2(ANCHOR.x, ANCHOR.y)
	ci.draw_line(anchor + Vector2(-8, 0), anchor + Vector2(8, 0), Color(0.2, 0.2, 0.2, 0.6), 1.0)
	ci.draw_line(anchor + Vector2(0, -6), anchor + Vector2(0, 6), Color(0.2, 0.2, 0.2, 0.6), 1.0)


func _queue_rig_redraw() -> void:
	if _rig_overlay != null and is_instance_valid(_rig_overlay):
		_rig_overlay.queue_redraw()


## 编辑器里按 preview_phase / preview_pose 摆一次姿势（不跑 _process）
func _refresh_preview() -> void:
	if not Engine.is_editor_hint() or _canvas == null or not is_inside_tree():
		return
	_rot.clear()
	for k in _joint_nodes.keys():
		_rot[k] = 0.0
	phase = clampf(preview_phase, 0.0, 1.0)
	match preview_pose:
		"walk":
			_pose_walk()
		"attack":
			_action_time = 0.18      # 挥出的峰值附近，最能看出层级
			_pose_attack()
		"hurt":
			_action_time = 0.2
			_pose_hurt()
		_:
			_pose_idle()
	_apply_rot()
	_apply_swing_z()
	_queue_rig_redraw()


func _joint_canvas_pos(jname: String) -> Vector2:
	for entry in JOINTS:
		if entry[0] == jname:
			return entry[2]
	return Vector2.ZERO


# ---------------------------------------------------------------- 部件

func _rebuild_parts() -> void:
	for s in _sprites:
		if is_instance_valid(s):
			s.queue_free()
	_sprites.clear()
	_springs.clear()
	for n in _joint_nodes.values():
		for c in n.get_children():
			if c is SpringJoint:
				c.queue_free()

	if visual == null or _canvas == null:
		return

	for slot in visual.equipped.keys():
		var part: PartDef = visual.equipped.get(slot)
		if part == null:
			continue
		var jname: String
		if part.bone != &"":
			jname = String(part.bone)
		elif SLOT_JOINT.has(slot):
			jname = String(SLOT_JOINT[slot])
		else:
			# 以前这里兜底成 "hip"：少登记一个槽位，部件会静默长在胯上。
			# 宁可报出来，也不要在美术阶段才发现"耳环戴在腰上"。
			push_warning("JointDoll: 槽位 %s 没有在 SLOT_JOINT 登记关节，已跳过" % slot)
			continue
		var node: Node2D = _joint_nodes.get(jname)
		if node == null:
			push_warning("JointDoll: 槽位 %s 找不到关节 %s" % [slot, jname])
			continue

		var host: Node2D = node
		if _has_spring(slot):
			var sj := SpringJoint.new()
			sj.name = "spring_%s" % slot
			sj.stiffness = spring_stiffness
			sj.damping = spring_damping
			sj.inertia = spring_inertia
			sj.drag = spring_drag
			sj.enabled = spring_enabled
			sj.gain = float(SPRING_GAIN.get(view, 1.0))
			# 弹簧枢轴放在该部件的挂点上；披风挂在胸口，头发挂在头上
			var pivot := _spring_pivot(slot)
			sj.position = pivot - _joint_canvas_pos(jname)
			node.add_child(sj)
			_springs[slot] = sj
			host = sj

		var s := Sprite2D.new()
		s.name = String(slot)
		s.centered = false
		# 贴图按画布坐标绘制，而枢轴节点绕自己的原点旋转。
		# 要让画布点 c 落到 pivot + R·(c - pivot)，Sprite 的 position 必须是 -pivot。
		s.position = -_part_pivot(slot, jname, host)
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		s.z_index = z_base + int(SLOT_Z.get(slot, 10)) + int(part.layer_offset)
		s.z_as_relative = false
		s.set_meta(&"part", part)
		s.set_meta(&"slot", slot)
		s.material = _make_material(part, slot)
		host.add_child(s)
		_sprites.append(s)

	_apply_view()
	_apply_z_order()


func _has_spring(slot: StringName) -> bool:
	if slot in SPRING_SLOTS:
		return true
	return spring_on_hair and slot in SPRING_SLOT_HAIR


func _spring_pivot(slot: StringName) -> Vector2:
	match slot:
		&"cape": return Vector2(128, 108)       # 肩背处
		&"hair_back": return Vector2(128, 62)   # 发根（头顶偏后），不是脖子
		_: return Vector2(128, 100)


## 部件的枢轴在画布坐标系里的位置
func _part_pivot(slot: StringName, jname: String, host: Node2D) -> Vector2:
	if host is SpringJoint:
		return _spring_pivot(slot)
	return _joint_canvas_pos(jname)


func _make_material(part: PartDef, slot: StringName) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/part_tint.gdshader")
	var mk: Texture2D = part.tint_masks.get(VIEW_NAMES[view], part.tint_mask)
	m.set_shader_parameter("use_mask", mk != null)
	if mk != null:
		m.set_shader_parameter("tint_mask", mk)
	var packed: Color = visual.tints.get(slot, Color(0.5, 1.0, 1.0))
	m.set_shader_parameter("hue_shift", packed.r - 0.5)
	m.set_shader_parameter("sat_mul", packed.g)
	m.set_shader_parameter("val_mul", packed.b)
	# 金属区（球关节/护手）：默认中性 = 保持原色
	var mt: Color = visual.tints_metal.get(slot, Color(0.5, 1.0, 1.0))
	m.set_shader_parameter("metal_hue_shift", mt.r - 0.5)
	m.set_shader_parameter("metal_sat_mul", mt.g)
	m.set_shader_parameter("metal_val_mul", mt.b)
	var sk: Color = visual.skin_tint
	m.set_shader_parameter("skin_hue_shift", sk.r - 0.5)
	m.set_shader_parameter("skin_sat_mul", sk.g)
	m.set_shader_parameter("skin_val_mul", sk.b)
	return m


# ---------------------------------------------------------------- 视图

func set_direction(d: int) -> void:
	d = wrapi(d, 0, 8)
	var m: Vector2i = DIR_TO_VIEW[d]
	direction = d
	if m.x != view:
		view = int(m.x)
		view_changed.emit(view)
	_apply_view()
	_apply_z_order()
	if Engine.is_editor_hint():
		_refresh_preview()


## 换表情（face 槽位换贴图，头骨/头发/鼻尖不动）。
## 可用值见 tools/gen_joint_art.py::FACE_EXPR
## （neutral / smile / angry / sad / surprise / blink）
func set_expression(expr: StringName) -> void:
	if visual == null:
		return
	visual.set_expression(expr)
	_apply_view()
	if Engine.is_editor_hint():
		_refresh_preview()


## 换装（outfit = slot -> 变体名；"" = 摘掉该槽位）。
## 三套现成的：{}（骑士）、{"body":"robe",...,"hat":"wizard"}（法师）、
## {"body":"leather",...,"hat":"hood"}（游侠）—— demo 的 O 键在轮着示范。
## 变体是另一张图不是另一个参数，所以整槽位重装（tints / 表情原地保留）
func set_outfit(outfit: Dictionary) -> void:
	if visual == null:
		return
	visual.apply_outfit(outfit)
	_rebuild_parts()
	_apply_view()
	_apply_z_order()
	if Engine.is_editor_hint():
		_refresh_preview()


## 按移动向量选方向（屏幕坐标系，y 向下）
func face_vector(v: Vector2) -> void:
	if v.length_squared() < 0.0001:
		return
	var oct := int(round(v.angle() / (PI / 4.0)))
	var table := {0: 6, 1: 7, 2: 0, 3: 1, 4: 2, -1: 5, -2: 4, -3: 3, -4: 2}
	set_direction(table.get(oct, 0))


func _apply_view() -> void:
	var m: Vector2i = DIR_TO_VIEW[direction]
	var vname: String = VIEW_NAMES[m.x]
	var mirrored: bool = m.y == 1
	for s in _sprites:
		var part: PartDef = s.get_meta(&"part")
		var tex: Texture2D = part.sheets.get(vname)
		s.visible = tex != null
		if tex != null:
			s.texture = tex
		# mask 跟着贴图一起换：五个视图形状不同，一张 mask 盖不住。
		# 没有 tint_masks 的旧部件退回单张 tint_mask（可能为空 = 不染色）
		if s.material is ShaderMaterial:
			var mat: ShaderMaterial = s.material
			var mk: Texture2D = part.tint_masks.get(vname, part.tint_mask)
			mat.set_shader_parameter("use_mask", mk != null)
			if mk != null:
				mat.set_shader_parameter("tint_mask", mk)
		# no_mirror：贴在身上的"有字"部件（旗号、盾徽、纹章）。
		# 整只人偶 scale.x=-1 会把字翻过来，这里给该图层再乘一次 -1 抵消。
		# 位置仍跟着镜像走（部件还在那条 mirrored 的胳膊上），只有图案不翻。
		s.scale.x = -1.0 if (mirrored and part.no_mirror) else 1.0
	# 镜像在整只人偶上做：逐图层 flip_h 只翻贴图不翻枢轴，图和轴心会错位
	scale.x = -1.0 if mirrored else 1.0
	# 弹簧的驱动量是屏幕 x，纯正面/背面要压掉，否则披风会左右乱扑
	for slot in _springs.keys():
		(_springs[slot] as SpringJoint).gain = float(SPRING_GAIN.get(view, 1.0))
	if Engine.is_editor_hint():
		_queue_rig_redraw()


func _apply_z_order() -> void:
	var is_back := direction in BACK_VIEW_DIRS
	# near == "" 表示正/背面（左右等距）：两侧都按「近」取，不能硬挑一边
	var near: String = NEAR_SIDE.get(view, "l")
	for s in _sprites:
		var slot: StringName = s.get_meta(&"slot")
		var part: PartDef = s.get_meta(&"part")
		var z: int = int(SLOT_Z.get(slot, 10))
		# 四肢：按「这一侧是否离镜头近」取两套 z 之一
		if LIMB_Z.has(slot):
			var side: String = "l" if String(slot).ends_with("_l") else "r"
			var is_near: bool = near == "" or side == near
			z = int(LIMB_Z[slot]["near" if is_near else "far"])
			# 背面：两只手臂都越过披风（远侧低一档，保留层次）
			if is_back and ARM_Z_ON_BACK.has(slot):
				z = int(ARM_Z_ON_BACK[slot]["near" if is_near else "far"])
		# 逐方向覆盖（披风、后发）：只在背面朝向生效，优先级最高
		if is_back and Z_ON_BACK.has(slot):
			z = int(Z_ON_BACK[slot])
		# 外部矩阵优先：只覆盖它写了的格子，没写的仍用上面推导出来的值
		var row: Dictionary = layer_z.get(VIEW_NAMES[view], {})
		if row.has(slot):
			z = int(row[slot])
		_z_static[slot] = z
		s.z_index = z_base + z + int(part.layer_offset)


## 摆动触发的层级切换：**同一个部件，摆到不同相位时该在身体前面还是后面**。
##
## 这套系统里 z 一直是"按视图查表"的静态值。但一只手臂从身体后面摆到前面时，
## 它在深度上是真的换了位置 —— 静态表表达不了，只能每帧算。
## 规则写在 layer_rules.json 的 swing 数组里，由设计器勾选生成，默认是空的：
##
##   {"slot":"arm_l", "joint":"shoulder_l",     # 看哪个槽位、哪个关节
##    "deg":8, "hysteresis":4,                  # 关节角 ≥8° 算"摆到前面"，≤4° 退回
##    "front":13, "back":8}                     # 正面朝向/背面朝向各自的 z
##
## 阈值必须**高于**手臂刚好脱离躯干轮廓时的角度，否则切换发生在手臂还压着胸口的
## 那一刻，画面会"啪"地跳一下。滞后 4° 是为了在阈值附近来回摆时不闪。
func _apply_swing_z() -> void:
	if swing_rules.is_empty():
		return
	var is_back := direction in BACK_VIEW_DIRS
	var by_slot := {}
	for s in _sprites:
		by_slot[s.get_meta(&"slot")] = s
	for r in swing_rules:
		var rd: Dictionary = r
		var slot := StringName(rd.get("slot", ""))
		var sp: Sprite2D = by_slot.get(slot)
		if sp == null:
			continue
		var joint := String(rd.get("joint", ""))
		if not _rot.has(joint):
			continue
		var ang := rad_to_deg(float(_rot[joint]))
		var deg_on := float(rd.get("deg", 8.0))
		var deg_off := deg_on - float(rd.get("hysteresis", 4.0))
		var hot: bool = _swing_hot.get(slot, false)
		if ang >= deg_on:
			hot = true
		elif ang <= deg_off:
			hot = false
		_swing_hot[slot] = hot
		var z: int = int(_z_static.get(slot, 10))
		if hot:
			var key := "back" if is_back else "front"
			var alt: Variant = rd.get(key)
			if alt != null:
				z = int(alt)
		var part: PartDef = sp.get_meta(&"part")
		sp.z_index = z_base + z + int(part.layer_offset)


# ---------------------------------------------------------------- 动画

func play(a: StringName) -> void:
	if a == action:
		return
	action = a
	_action_time = 0.0


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	# 编辑器里不跑循环动画：姿势由 preview_phase 一次性算（见 _refresh_preview）
	if Engine.is_editor_hint():
		return
	_time += delta
	_action_time += delta
	phase = fmod(phase + delta / maxf(0.05, stride_time), 1.0)

	_rot.clear()
	for k in _joint_nodes.keys():
		_rot[k] = 0.0

	match action:
		&"walk": _pose_walk()
		&"attack": _pose_attack()
		&"hurt": _pose_hurt()
		_: _pose_idle()

	_apply_rot()
	_apply_swing_z()
	_step_springs(delta)


func _pose_idle() -> void:
	var w := TAU * _time * 0.55
	_add_rot("chest", deg_to_rad(1.2 * sin(w)))
	_add_rot("head", deg_to_rad(-0.8 * sin(w)))
	_add_rot("shoulder_l", deg_to_rad(2.0 * sin(w)))
	_add_rot("shoulder_r", deg_to_rad(2.0 * sin(w + PI)))
	_set_bob(0.9 * sin(w))


func _pose_walk() -> void:
	var p: Dictionary = PROFILE[view]
	var w := TAU * phase
	var leg: float = p.leg
	var arm: float = p.arm
	var knee: float = p.knee

	if int(p.mode) == 0:
		# 侧向：前后摆。两条腿正好相反，一前一后
		_add_rot("hip_l", deg_to_rad(leg * sin(w)))
		_add_rot("hip_r", deg_to_rad(leg * sin(w + PI)))
		# 膝盖只在腿往后走时弯（抬不起来的那条不弯）
		_add_rot("knee_l", deg_to_rad(-knee * maxf(0.0, -sin(w + 0.55))))
		_add_rot("knee_r", deg_to_rad(-knee * maxf(0.0, -sin(w + PI + 0.55))))
	else:
		# 正面 / 背面：腿摆不到前后去，只能「抬脚」—— 而且是**竖直**抬。
		#
		# 这里原来是「膝盖转 -30°」。那是把小腿连同脚一起在**屏幕平面里**转：
		# 朝镜头走路时，脚会甩到腿的左边或右边，还带着一个斜面 ——
		# 也就是「正面看脚是横的 / 脚偏到一边去了」。
		# 前后方向的位移投影到屏幕上不是旋转，是**缩短**。所以 mode 1 一个角度都不加：
		#   · 把 hip_l/hip_r 竖直抬起来，整条腿跟着上移；
		#     大腿顶端本来就沉在躯干(152 以下)后面，抬起来只是让露出来的部分变短，
		#     这正是"腿朝镜头迈出去"的缩短投影；
		#   · 脚不旋转 —— 脚永远水平、永远正对镜头。
		var lift_l := maxf(0.0, sin(w))
		var lift_r := maxf(0.0, sin(w + PI))
		_lift("hip_l", -float(p.lift) * lift_l)
		_lift("hip_r", -float(p.lift) * lift_r)

	# 手跟腿反着摆：同侧手臂取同侧腿的反相
	_add_rot("shoulder_l", deg_to_rad(arm * sin(w + PI)))
	_add_rot("shoulder_r", deg_to_rad(arm * sin(w)))
	# 肘部弯曲。**符号以用户实际观感为准**：当前侧向视图取**正角**。
	# （tools/elbow_calib.gd 的 ±40° 定标图曾经给出"负角朝身前"，但实机看到的
	#   是反的 —— 定标图和实际骨架/贴图朝向不完全等价。所以别再拿那张图当准绳，
	#   以跑 demo/joint_demo.tscn 后看到的画面为准。）
	#   · 侧向视图（mode 0）：正角折向身前；常驻底弯 ELBOW_REST_DEG，
	#     前摆时再叠加摆幅的一半 —— 只弯 ±6° 读不出「屈肘」，像肘部别了一下。
	#   · 正/背面（mode 1）：「朝身前」= 朝镜头，屏幕上用小角度**内收**代替
	#     （左手负角、右手正角），幅度跟摆臂走，两侧符号是镜像的。
	#
	# 想整体反相：把下面四行的正负号全反过来（mode 0 两行 + mode 1 两行），
	# 别只改一侧，否则两只手又不同步。
	if int(p.mode) == 0:
		_add_rot("elbow_l", deg_to_rad(ELBOW_REST_DEG + arm * 0.5 * (0.5 - 0.5 * sin(w))))
		_add_rot("elbow_r", deg_to_rad(ELBOW_REST_DEG + arm * 0.5 * (0.5 + 0.5 * sin(w))))
	else:
		_add_rot("elbow_l", deg_to_rad(-arm * 0.45 * (0.5 - 0.5 * sin(w))))
		_add_rot("elbow_r", deg_to_rad(arm * 0.45 * (0.5 + 0.5 * sin(w))))

	# 腿摆一个来回，身体颠两次：竖直位移取 2× 频率
	_set_bob(p.bob * sin(2.0 * w + PI * 0.5))
	# 上半身轻微反向扭，头部再抵消一点，避免"整块木头在晃"。
	# 只在侧向（mode 0）做：正面/背面时这点旋转在屏幕上是"肩膀歪一下"，
	# 而真人朝镜头走路，肩膀是平的 —— 扭了反而假。
	var sway: float = 1.6 if int(p.mode) == 0 else 0.0
	_add_rot("chest", deg_to_rad(-sway * sin(w)))
	_add_rot("head", deg_to_rad(sway * sin(w)))


func _pose_attack() -> void:
	var t := clampf(_action_time / 0.45, 0.0, 1.0)
	# 前 40% 挥出，后 60% 收回
	var k := sin(clampf(t / 0.4, 0.0, 1.0) * PI) if t < 0.4 else \
			sin(clampf((1.0 - t) / 0.6, 0.0, 1.0) * PI)
	# 手臂从下垂转向前方用正角度。镜像侧不用反号：
	# 实测（tools/facing_probe.gd）rot=+95° 在 scale.x=+1 时朝 -x、在 scale.x=-1 时朝 +x，
	# 正好各自对应「视图朝左」和「镜像后朝右」，两边都朝前。
	_add_rot("shoulder_r", deg_to_rad(-95.0 * k))
	_add_rot("elbow_r", deg_to_rad(25.0 * k))
	_add_rot("chest", deg_to_rad(7.0 * k))
	_add_rot("head", deg_to_rad(-5.0 * k))
	_add_rot("shoulder_l", deg_to_rad(-12.0 * k))


func _pose_hurt() -> void:
	var t := clampf(_action_time / 0.4, 0.0, 1.0)
	var k := sin(t * PI)
	_add_rot("chest", deg_to_rad(-14.0 * k))
	_add_rot("head", deg_to_rad(-16.0 * k))
	_add_rot("shoulder_l", deg_to_rad(-22.0 * k))
	_add_rot("shoulder_r", deg_to_rad(-22.0 * k))
	_set_bob(-2.0 * k)


func _add_rot(jname: String, rad: float) -> void:
	if _rot.has(jname):
		_rot[jname] += rad


func _set_bob(px: float) -> void:
	_bob = px

func _lift(jname: String, px: float) -> void:
	_lift_offsets[jname] = _lift_offsets.get(jname, 0.0) + px


func _apply_rot() -> void:
	for jname in _joint_nodes.keys():
		var n: Node2D = _joint_nodes[jname]
		n.rotation = _rot.get(jname, 0.0)
		var base: Vector2 = _base_pos[jname]
		if jname == "hip":
			n.position = base + Vector2(0, _bob)
		else:
			n.position = base + Vector2(0, _lift_offsets.get(jname, 0.0))
	# 单帧清空：抬脚偏移只在当帧有效
	_lift_offsets.clear()
	# 最后套用手动姿势。放在循环之后，是因为上面那段每次都会把 rotation 重写回程序化值
	if not editor_pose.is_empty():
		for jname in editor_pose.keys():
			var n2: Node2D = _joint_nodes.get(jname)
			if n2 != null:
				var r: float = float(editor_pose[jname])
				_rot[jname] = r
				n2.rotation = r


# ---------------------------------------------------------------- 编辑器摆姿势接口
# 给 addons/rig_editor 用。前缀 editor_ 是刻意的：一眼能看出这些不该在游戏逻辑里调。

## 某个关节的**当前**角度（弧度）。没手动改过就取程序化算出来的值
func editor_joint_angle(jname: String) -> float:
	if editor_pose.has(jname):
		return float(editor_pose[jname])
	return float(_rot.get(jname, 0.0))


## 手动设一个关节的角度（弧度）。会立刻写进节点 + 记进 editor_pose
func editor_set_joint_angle(jname: String, rad: float) -> void:
	if not _joint_nodes.has(jname):
		return
	editor_pose[jname] = rad
	_rot[jname] = rad
	(_joint_nodes[jname] as Node2D).rotation = rad
	_queue_rig_redraw()
	editor_pose_changed.emit()


## 关节枢轴的世界坐标（编辑器里算拖拽角度、画手柄都用它）
func editor_joint_global_pos(jname: String) -> Vector2:
	var n: Node2D = _joint_nodes.get(jname)
	return n.global_position if n != null else global_position


## 清掉手动姿势，回到程序化姿势
func editor_clear_pose() -> void:
	editor_pose.clear()
	_refresh_preview()
	editor_pose_changed.emit()


## 导出当前手动姿势（关节名 -> 角度制），给插件存 JSON 用
func editor_pose_degrees() -> Dictionary:
	var out := {}
	for jname in editor_pose.keys():
		out[jname] = rad_to_deg(float(editor_pose[jname]))
	return out


## 调试用：当前实际生效的 z 表（已扣掉 z_base）。给 tools/zdump.gd 和 HUD 用
func z_map() -> Dictionary:
	var out := {}
	for s in _sprites:
		out[s.get_meta(&"slot")] = s.z_index - z_base
	return out


## 调试用：本帧某个关节的旋转（弧度）。给 tools/swing_probe.gd 校验摆动规则
func _get_rot(jname: String) -> float:
	return float(_rot.get(jname, 0.0))


## 调试用：读某个槽位当前的弹簧角度（度）
func spring_angle_deg(slot: StringName) -> float:
	var sj: SpringJoint = _springs.get(slot)
	return rad_to_deg(sj.angle) if sj != null else 0.0


## 调试用：当前实际挂了弹簧的槽位。默认只有披风 —— 头发是刚性的
func spring_slots() -> Array:
	return _springs.keys()


func _step_springs(delta: float) -> void:
	for slot in _springs.keys():
		var sj: SpringJoint = _springs[slot]
		# 驱动源用「挂弹簧的那个关节」的世界位置 —— 人偶整体移动/急停都在这里体现
		var driver_name := "head" if slot != &"cape" else "chest"
		var node: Node2D = _joint_nodes.get(driver_name)
		if node != null:
			sj.step(delta, node.global_position)
