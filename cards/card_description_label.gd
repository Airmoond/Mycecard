## 按实际排版高度缩小字号，不截断文案；空间恢复后重新从场景字号尝试。
class_name CardDescriptionLabel
extends RichTextLabel

## 每次拟合文字时重新尝试的基准字号，不随临时缩小而降低。
@onready var _base_font_size:int = get_theme_font_size("normal_font_size");


## 连接尺寸变化通知，并延迟按实际可用高度拟合文字。
func _ready()->void:
	resized.connect(_fit_text);
	_fit_text.call_deferred();


## 浏览与手牌的显示尺寸改变时，从对应基准字号重新拟合全部文字。
func set_base_font_size(value:int)->void:
	_base_font_size = value;
	if is_node_ready():
		_fit_text();


## 替换描述文本，并从基准字号重新拟合显示高度。
func set_description(value:String)->void:
	text = value;
	_fit_text();


## 从基准字号逐步缩小文字，直到内容高度适合当前区域或字号降至 [code]1[/code]。
func _fit_text()->void:
	var font_size:int = _base_font_size;
	add_theme_font_size_override("normal_font_size", font_size);
	var available_height:float = size.y - get_theme_stylebox("normal").get_minimum_size().y;
	while font_size > 1 and get_content_height() > available_height:
		font_size -= 1;
		add_theme_font_size_override("normal_font_size", font_size);
