#!/usr/bin/env python3
"""
ANE Compatibility Analyzer for Kokoro TTS Model

Identifies layers that may cause fallback from Apple Neural Engine to GPU/CPU.

Requirements:
    pip install coremltools

Usage:
    python analyze_ane.py --model kokoro_21_15s.mlpackage
    python analyze_ane.py --model kokoro_21_15s.mlpackage --json
"""

import argparse
import json
import sys

try:
    import coremltools as ct
except ImportError:
    print("Error: coremltools not installed.")
    print("Run: pip install coremltools")
    sys.exit(1)


# Operations known to be problematic for ANE
ANE_PROBLEMATIC_OPS = {
    # Custom or unsupported operations
    "custom",
    "customLayer", 
    
    # Dynamic shape operations (often force CPU)
    "reshape_dynamic",
    "slice_dynamic",
    "gather_nd",
    
    # Large tensor operations (may exceed ANE memory)
    "einsum",
}

# Operations that work well on ANE
ANE_OPTIMIZED_OPS = {
    "conv", "conv2d", "depthwise_conv2d", "conv_transpose",
    "linear", "matmul", "batch_matmul",
    "relu", "gelu", "silu", "sigmoid", "tanh", "leaky_relu",
    "add", "mul", "sub", "div", "real_div",
    "softmax", "layer_norm", "batch_norm", "instance_norm",
    "reshape", "transpose", "squeeze", "expand_dims", "flatten",
    "concat", "split", "slice_by_index", "gather",
    "reduce_mean", "reduce_sum", "reduce_max",
    "embedding", "pad", "upsample_nearest_neighbor",
}

# Tensor shape constraints for ANE
ANE_CONSTRAINTS = {
    "max_tensor_size_mb": 256,
    "max_batch_size": 32,
    "preferred_channel_alignment": 16,
    "max_sequence_length": 2048,
}


def analyze_ml_program(model_path: str) -> dict:
    """Analyze ML Program format model for ANE compatibility."""
    print(f"\n🔍 Analyzing model: {model_path}")
    
    model = ct.models.MLModel(model_path)
    spec = model.get_spec()
    
    results = {
        "model_path": model_path,
        "format": "unknown",
        "ane_compatible": True,
        "warnings": [],
        "blocking_issues": [],
        "operations": {},
        "input_shapes": {},
        "output_shapes": {},
        "recommendations": []
    }
    
    # Determine model format
    model_type = spec.WhichOneof('Type')
    if model_type == 'mlProgram':
        results["format"] = "mlprogram"
        analyze_mlprogram_ops(spec, results)
    elif model_type == 'neuralNetwork':
        results["format"] = "neuralNetwork"
        analyze_neural_network_ops(spec, results)
    else:
        results["format"] = model_type or "unknown"
    
    # Analyze input/output shapes
    for input_desc in model.input_description:
        name = input_desc.name
        if hasattr(input_desc, 'type'):
            if hasattr(input_desc.type, 'multiArrayType'):
                shape = list(input_desc.type.multiArrayType.shape)
                results["input_shapes"][name] = shape
    
    for output_desc in model.output_description:
        name = output_desc.name
        if hasattr(output_desc, 'type'):
            if hasattr(output_desc.type, 'multiArrayType'):
                shape = list(output_desc.type.multiArrayType.shape)
                results["output_shapes"][name] = shape
    
    # Generate recommendations
    results["recommendations"] = generate_recommendations(results)
    
    return results


def analyze_mlprogram_ops(spec, results: dict):
    """Analyze ML Program operations."""
    program = spec.mlProgram
    
    for function in program.functions:
        func_name = function.name or "main"
        
        for block in function.block_specializations:
            for op in block.operations:
                op_type = op.type
                results["operations"][op_type] = results["operations"].get(op_type, 0) + 1
                
                # Check for problematic operations
                op_lower = op_type.lower()
                if op_lower in ANE_PROBLEMATIC_OPS:
                    results["warnings"].append(
                        f"Operation '{op_type}' may cause ANE fallback"
                    )
                
                # Check for custom layers
                if "custom" in op_lower:
                    results["blocking_issues"].append(
                        f"Custom layer '{op_type}' not supported on ANE"
                    )
                    results["ane_compatible"] = False


def analyze_neural_network_ops(spec, results: dict):
    """Analyze Neural Network format operations."""
    nn = spec.neuralNetwork
    
    for layer in nn.layers:
        layer_type = layer.WhichOneof('layer')
        results["operations"][layer_type] = results["operations"].get(layer_type, 0) + 1
        
        # Check for custom layers
        if layer_type == "custom":
            results["blocking_issues"].append(
                f"Custom layer '{layer.name}' not supported on ANE"
            )
            results["ane_compatible"] = False
        
        # Check for problematic layer types
        if layer_type.lower() in ANE_PROBLEMATIC_OPS:
            results["warnings"].append(
                f"Layer '{layer.name}' ({layer_type}) may cause ANE fallback"
            )


def generate_recommendations(results: dict) -> list:
    """Generate recommendations based on analysis."""
    recommendations = []
    
    if not results["ane_compatible"]:
        recommendations.append(
            "❌ Model contains blocking issues. Custom layers must be replaced "
            "with supported operations or the model must be re-exported."
        )
    
    if results["warnings"]:
        recommendations.append(
            "⚠️ Some operations may cause partial ANE fallback. "
            "Profile with Instruments to measure actual ANE utilization."
        )
    
    # Check for operations that could be Float16
    ops = results.get("operations", {})
    has_compute_ops = any(
        op.lower() in {"matmul", "linear", "conv", "conv2d"} 
        for op in ops
    )
    if has_compute_ops:
        recommendations.append(
            "💡 Consider Float16 precision for compute-heavy operations. "
            "Use `compute_precision=ct.precision.FLOAT16` during conversion."
        )
    
    # Check for non-aligned dimensions
    if any("conv" in op.lower() for op in ops):
        recommendations.append(
            "💡 Ensure convolution channel dimensions are multiples of 16 "
            "for optimal ANE tile processing."
        )
    
    # Check for large attention operations
    if any("attention" in op.lower() or "softmax" in op.lower() for op in ops):
        for name, shape in results.get("input_shapes", {}).items():
            if shape and len(shape) >= 2:
                seq_len = max(shape)
                if seq_len > ANE_CONSTRAINTS["max_sequence_length"]:
                    recommendations.append(
                        f"⚠️ Sequence length {seq_len} may exceed ANE limits. "
                        "Consider chunking input for very long sequences."
                    )
    
    if not recommendations:
        recommendations.append(
            "✅ Model appears well-optimized for ANE execution."
        )
    
    return recommendations


def print_report(results: dict):
    """Print formatted analysis report."""
    print("\n" + "=" * 60)
    print("ANE COMPATIBILITY REPORT")
    print("=" * 60)
    
    print(f"\nModel: {results['model_path']}")
    print(f"Format: {results['format']}")
    print(f"ANE Compatible: {'✅ Yes' if results['ane_compatible'] else '❌ No'}")
    
    if results["input_shapes"]:
        print("\n📥 INPUT SHAPES:")
        for name, shape in results["input_shapes"].items():
            print(f"   • {name}: {shape}")
    
    if results["output_shapes"]:
        print("\n📤 OUTPUT SHAPES:")
        for name, shape in results["output_shapes"].items():
            print(f"   • {name}: {shape}")
    
    if results["blocking_issues"]:
        print("\n🚫 BLOCKING ISSUES:")
        for issue in results["blocking_issues"]:
            print(f"   • {issue}")
    
    if results["warnings"]:
        print("\n⚠️ WARNINGS:")
        for warning in results["warnings"]:
            print(f"   • {warning}")
    
    print("\n📊 OPERATION COUNTS:")
    sorted_ops = sorted(results["operations"].items(), key=lambda x: -x[1])
    for op, count in sorted_ops[:20]:
        op_lower = op.lower()
        if op_lower in ANE_OPTIMIZED_OPS or any(opt in op_lower for opt in ANE_OPTIMIZED_OPS):
            status = "✅"
        elif op_lower in ANE_PROBLEMATIC_OPS:
            status = "❌"
        else:
            status = "⚠️"
        print(f"   {status} {op}: {count}")
    
    if len(sorted_ops) > 20:
        print(f"   ... and {len(sorted_ops) - 20} more operation types")
    
    if results["recommendations"]:
        print("\n💡 RECOMMENDATIONS:")
        for rec in results["recommendations"]:
            print(f"   {rec}")
    
    print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Analyze CoreML model for ANE compatibility"
    )
    parser.add_argument(
        "--model", "-m", 
        required=True, 
        help="Path to .mlpackage or .mlmodelc"
    )
    parser.add_argument(
        "--json", "-j", 
        action="store_true", 
        help="Output as JSON"
    )
    
    args = parser.parse_args()
    
    results = analyze_ml_program(args.model)
    
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_report(results)


if __name__ == "__main__":
    main()

