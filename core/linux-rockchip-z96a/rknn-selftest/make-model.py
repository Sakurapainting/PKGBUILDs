from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
from rknn.api import RKNN

out = Path(__file__).resolve().parent
shape_in = [1, 8, 32, 32]
shape_out = [1, 16, 30, 30]
weights = (np.arange(16 * 8 * 3 * 3, dtype=np.float32) % 7 - 3).reshape(16, 8, 3, 3) / 8
bias = (np.arange(16, dtype=np.float32) - 8) / 4
node = helper.make_node('Conv', ['input', 'weights', 'bias'], ['output'], kernel_shape=[3, 3])
graph = helper.make_graph(
    [node], 'z96a_conv', [helper.make_tensor_value_info('input', TensorProto.FLOAT, shape_in)],
    [helper.make_tensor_value_info('output', TensorProto.FLOAT, shape_out)],
    [numpy_helper.from_array(weights, 'weights'), numpy_helper.from_array(bias, 'bias')],
)
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 13)], ir_version=8)
onnx.checker.check_model(model)
onnx.save(model, out / 'conv.onnx')

rknn = RKNN(verbose=True)
try:
    assert rknn.config(target_platform='rk3568') == 0
    assert rknn.load_onnx(model=str(out / 'conv.onnx')) == 0
    assert rknn.build(do_quantization=False) == 0
    assert rknn.export_rknn(str(out / 'conv.rknn')) == 0
finally:
    rknn.release()
