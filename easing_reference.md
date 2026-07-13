# 缓动函数 (Easing) 参考

## XML 中的表示

关键帧可以通过 `e` 属性指定缓动:

```xml
<kf t="1000" v="100,200" e="cubicBezier 0.0 0.0 0.58 1.0" />
```

不写 `e` 属性时为线性缓动:
```xml
<kf t="1000" v="100,200" />
```

## 缓动类型总览

### 1. Linear (默认)

无 `e` 属性,或不写。最简单的线性插值。

```
f(t) = t
```

### 2. Step

格式: `step <step_length> <smoothing>`

阶梯式缓动,值在每一步中保持不变,在步边界跳跃。

| 参数 | 说明 | 范围 |
|------|------|------|
| step_length | 每步持续时间 (t-space) | 0-1 |
| smoothing | 步末尾的平滑过渡量 | 0 (瞬时跳变) - 1 (完全平滑) |

示例:
- `step 1.0 0.0` — 整个动画只有一步,在 t=1.0 时跳变
- `step 0.25 0.0` — 4 步均分,无平滑 (楼梯效果)
- `step 0.25 0.5` — 4 步,每步末尾有平滑过渡

**算法核心** (来自 AM 源码 `StepEasing.java`):
1. 将 t 按 step_length 分段
2. 计算段内位置 within_step = t % step_length
3. 用 smoothstep 处理段末尾的过渡

### 3. CubicBezier

格式: `cubicBezier <x1> <y1> <x2> <y2>`

三次贝塞尔缓动。控制点: P0=(0,0), P1=(x1,y1), P2=(x2,y2), P3=(1,1)。

| 参数 | 说明 | 约束 |
|------|------|------|
| x1, y1 | 第一控制点 | x1 被 clamp 到 ≤0.95 |
| x2, y2 | 第二控制点 | x2 被 clamp 到 ≥0.05 |

常见预设:
- `cubicBezier 0.0 0.0 0.58 1.0` — ease-out (快入慢出)
- `cubicBezier 0.42 0.0 1.0 1.0` — ease-in (慢入快出)
- `cubicBezier 0.42 0.0 0.58 1.0` — ease-in-out

**求解方法**: 牛顿迭代法查找给定 x 对应的 t,然后计算 y(t)。

### 4. Bounce

格式: `bounce <p1> <p2>`

弹跳缓出 (在终点附近弹跳)。实现来自 AM `BounceEasing.java`。

| 参数 | 说明 | 默认 |
|------|------|------|
| p1 (firstStepLength) | 第一个弹跳周期的长度 | - |
| p2 (bounciness) | 弹力衰减系数 | - |

**算法**: 
1. t 加上 p1/2 的偏移
2. 从第一个弹跳周期开始,周期长度 = p1
3. 每个周期内用抛物线计算值 (周期中心最低)
4. 每过一个周期,周期长度 *= p2, 振幅 *= p2
5. 振幅 < 0.005 时返回 1.0

### 5. Reverse Bounce

格式: `reverse bounce <p1> <p2>`

弹跳缓入 (在起点附近弹跳)。相当于 Bounce 的翻转。

```
f(t) = 1 - bounce(1 - t, p1, p2)
```

### 6. Cyclic

格式: `cyclic <step_length> <sharpness> <skew> <decay> <reserved>`

周期性振荡缓动。实现来自 AM `CyclicEasing.java`。

| 参数 | 说明 | 默认值 |
|------|------|--------|
| step_length | 振荡周期 (t-space) | 0.2857143 |
| sharpness | cosine(0) 与 triangle(1) 波形的混合比 | 0.0 |
| skew | 峰位偏移 (0-1) | 0.5 |
| decay | 向线性衰减的趋势 | 0.0 |
| reserved | 保留 (未使用) | 0.0 |

**算法**:
1. 对每个周期,混合 cosine 波和 triangle 波
2. 应用 skew 偏移波峰位置
3. 应用 decay: 混入线性进度
4. 处理 t≈1 的边界情况

### 7. Elastic

格式: `elastic <step_length> <attack> <decay> <magnitude>`

弹簧式弹性缓动。实现来自 AM `ElasticEasing.java`。

| 参数 | 说明 | 默认值 |
|------|------|--------|
| step_length | 弹性周期 | 0.25 |
| attack | 攻击强度 | 1.0 |
| decay | 衰减系数 | 0.5 |
| magnitude | 振幅 | 1.0 |

**算法**:
- 基本公式: `cos(π*t/step) * (1-t)^(decay²*15+1)` 用于产生衰减振荡
- 在第一个 cycle 内混合 cos ramp 和弹性曲线 (用 blend_factor = (t/step)^3)

### 8. ElasticStep

格式: `elasticStep <step_length> <magnitude>`

阶梯弹性缓动。每个步长内执行一次弹性缓动。实现来自 AM `ElasticStepEasing.java`。

| 参数 | 说明 | 默认值 |
|------|------|--------|
| step_length | 每个步长的持续时间 | 0.2 |
| magnitude | 振幅 | 0.5 |

## 缓动字符串解析规则

1. 按空格分割
2. `reverse` 前缀 → 检查下一个 token 是否为 `bounce`
3. 第一 token 匹配: `step` / `cubicBezier` / `bounce` / `cyclic` / `elastic` / `elasticStep`
4. 后续 token 按 float 解析为参数
5. 无法解析的 → 回退到 Linear

## 在序列化时的注意事项

- Linear 不写 `e` 属性
- 所有数值参数用空格分隔
- Float 格式: 避免科学计数法,使用 `0.0` 而非 `0` 或 `0e0`
- 示例: `"cubicBezier 0.0 0.0 0.58 1.0"` 而非 `"cubicBezier 0,0,0.58,1.0"`
