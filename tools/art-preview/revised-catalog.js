export const removedIds=new Set(['immune_phago','immune_chemo','immune_mark','immune_duties','cancer_jump','cancer_warburg',
  'immune_move','immune_attack','immune_purify','immune_draw','immune_memory','cancer_move','cancer_colonize','cancer_draw',
  'cancer_proliferate','cancer_erosion','cancer_solidify','cancer_pressure','shared_vessel','cancer_ossify']);
export const requestedSelections={immune_antibody:0,immune_toxin:0,cancer_homing:1,
  immune_differentiate:2,immune_respire:0,immune_revive:0,cancer_revive:0};
const updates={
  marrow:{description:'骨梁、髓质与孔隙覆盖整个六边形，包含独立侧壁，不露出健康或癌性底块。',note:'骨白、灰褐、髓红的整格组织纹理；空仓时减少髓质亮点。'},
  immune_antibody:{tag:'原 A 衍生 · 三案',description:'沿用 A 的 Y 形抗体直射，对比一次重击、三连点射与重型穿透。',note:'旧 B 弧线簇与旧 C 净化方案已舍弃。三案均取消命中叉，以胞体震动、瞬间亮斑和碎粒表现打击。',names:['A · 单发重击','A · 三连点射','A · 重型穿透'],details:['标准 Y 形抗体直射，命中亮斑与短促扩散碎粒。','三枚 Y 形抗体沿同一直线连续命中，形成三拍后坐。','较大的 Y 形抗体快速抵达，更强震动和向后飞散的穿透碎屑。']},
  immune_toxin:{tag:'原 A 衍生 · 三案',description:'保留 A 的紫色颗粒发射，覆盖脚下和六个邻格，比较三种释放节奏。',note:'旧 B 毒环与旧 C 上方沉降已舍弃；取消全部紫色组织轮廓与地面圈，范围只通过颗粒方向和坏死暗纹呈现。',names:['A · 同步散射','A · 三波连发','A · 依次扫射'],details:['七格同步接收一束颗粒，节奏最直接。','三轮细颗粒沿相同路径射出，形成持续压制感。','从中心开始依次射向六个方向，以顺序变化突出流动感。']},
  immune_lyse:{description:'T 细胞先送入颗粒，再分别呈现中心炸裂、三点连爆和竖向喷裂，最后留下坏死格。',note:'三案区别是爆裂形状与节奏：向外一炸、横向三连爆、向上喷射后回落。',phases:['颗粒输送','内部爆裂','坏死格残留'],names:['中心炸裂','三点连爆','竖向喷裂'],details:['橙色颗粒集中注入中心，一次向四周炸开。','三颗琥珀颗粒分头钻入左中右三处，依次爆裂。','冰蓝颗粒注入后，碎片向上喷起再落下，呈明显竖向轮廓。']},
  cancer_homing:{variants:[1],tag:'B · 单案预览',description:'双端血门转移，抵达后向新感染邻格送出血粒，每格变色时散出碎光。',note:'仅保留 B 一张预览；感染粒子跟随各格转化时机逐格出现。',names:['','双端血门 · 感染扩散',''],details:['','双端血门连接落点；落点和三个新感染邻格均有独立血色粒子。','']},
  cancer_pseudopod:{description:'B 格周围的癌组织伸出触手，抓住细胞边缘，将其从 A 拉到 B。',note:'出发 A 和目标 B 均不冒触手；仅其他五个邻格提供牵引。',names:['低弧牵引','高弧抓取','强力拉推'],details:['五个有效邻格的低弧触手协同牵引。','触手抬高，抓取胞体轮廓更加明显。','更高的弧度表现合力拉推，落位后收回。']},
  cancer_armor:{description:'两枚小护盾沿平行于地面的圆形轨道缓慢环绕细胞。',note:'低透明度、细像素轮廓；取消球面和整圈轨道线，前后分层减少遮挡。',phases:['护盾环绕','护盾环绕','护盾环绕'],names:['灰粉小盾','灰蓝小盾','灰青小盾'],details:['柔和灰粉色，存在感轻。','低饱和灰蓝色小盾。','半透明灰青色小盾。']},
  immune_adhesion:{description:'新版头顶菱形标记沿细粒轨迹传给两格内癌细胞。',note:'与独立标记页共用菱心、双翼切角与环行碎片；新标记本阶段不继续连锁。',names:['绯红猎印传递','紫晶冠印传递','冰蓝追迹传递'],details:['绯红碎粒抵达后收束为新版猎印。','紫晶碎粒传递，冠印在目标头顶成形。','冰蓝粒子传递，追迹核心在目标头顶收束。']},
  cancer_ossify:{description:'矿化颗粒出现在细胞四周，后侧高骨梁与前侧短骨梁先后长出。',note:'后侧骨梁先画、细胞居中、前侧短骨梁后画；矿化颗粒位于外缘，避免特效被胞体全部遮挡。',names:['骨白骨梁','灰青矿化','暖骨晶柱'],details:['前后骨梁包围胞体，前景短骨梁清晰可见。','灰青骨梁从外缘长起，保留细胞脸部轮廓。','暖白晶柱在两侧和前沿交织。']},
  cancer_barrier:{description:'六枚向外倾斜的骨牙嵌在低矮基座上，中央凹座承托细胞。',note:'重新绘制为少量有厚度的骨牙、连续底盘和内凹承托面，去掉整排密集栅栏。',names:['骨牙底盘','冷钢骨座','外倾骨棘'],details:['米白骨牙与深褐底盘，轮廓更简洁。','冷灰蓝基座，骨牙保持低矮。','略高的暖色外倾骨棘，中央保留完整胞体。']},
  cancer_respire:{description:'所处连通块的癌性组织持续向细胞输送能量，暖色粒子从各格汇入胞体。',note:'粒子起点是同一连通块的癌性组织，终点为细胞。',names:['铜橙输能','琥珀输能','玫红输能'],details:['铜橙粒子汇入胞体。','更亮的琥珀能量流。','暗玫红的组织代谢粒子。']},
  immune_respire:{note:'已选 A；保留吸收颗粒，取消加号形闪光。'},
  immune_revive:{note:'已选 A；保留胞体重组，取消底部光圈。'},
  cancer_mutate:{description:'双股像素粒子在胞体周围变化，结束时只留下不同的粒子消散。',note:'已移除画面内文字提示、记忆卡与加号。',names:['双股消散','碎粒消散','能量逸散'],details:['双股粒子自然散去。','少量红色碎粒消散。','能量粒子向外逸散。']}
};
export function revise(item){return {...item,...updates[item.id]};}
export const extraItems=[
  {id:'necrosis',name:'坏死格',group:'组织纹理',tag:'简洁整格纹理',description:'整块灰褐底色，仅保留两处短裂纹和少量淡色像素。',note:'去掉密集噪点与放射裂缝；裂解残留同步使用简化纹理。',phases:['坏死组织','坏死组织','坏死组织'],names:['灰色干枯','褐色坏死','冷灰塌陷'],details:['灰色底面与稀疏裂纹。','暖褐底面与稀疏裂纹。','冷灰底面与稀疏裂纹。']},
  {id:'mark_visual',name:'癌细胞头顶标记',group:'状态特效',tag:'重新绘制',description:'仅在癌细胞头顶形成醒目的悬浮标记，保留细胞轮廓与地面。',note:'独立状态美术，不再显示原 I-标记技能页。',phases:['标记收束','悬浮维持','状态保留'],names:['绯红猎印','紫晶冠印','冰蓝追迹'],details:['红色菱心、双翼切角与环行碎片。','紫晶色菱心和悬浮棱角。','冰蓝色识别核心与冷光粒子。']}
];
