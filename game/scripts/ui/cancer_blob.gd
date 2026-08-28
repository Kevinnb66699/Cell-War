## cancer_blob.gd —— 癌细胞占位图形
##
## **癌细胞精灵一张都还没有** —— PRD 把种类换成 4 种真实癌症之后，旧的 6 种全部作废。
## 这里故意用几何形状占位，而不是拿免疫细胞的贴图改个色：改色会让人以为那就是美术。
## 美术到位后本内部类整个删掉，和免疫细胞一样换成 Sprite2D 即可。
class_name CWCancerBlob
extends Node2D

const R := 9.0


## 脚底落在原点，和免疫细胞贴图的锚点一致
func _draw() -> void:
	draw_circle(Vector2(0, -R), R, Color("8a4a12"))
	draw_circle(Vector2(0, -R), R - 2.0, Color("ffb03a"))
	draw_circle(Vector2(0, -R - 1.0), 3.0, Color("8a4a12"))