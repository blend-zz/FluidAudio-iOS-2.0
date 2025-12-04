#!/usr/bin/env python3
"""
Kokoro TTS Model Quantization Script
Converts Float32 CoreML model to Float16 for reduced size (~50% reduction).

Requirements:
    pip install coremltools torch onnx numpy

Usage:
    python quantize_kokoro.py --input kokoro_21_15s.mlpackage --output kokoro_21_15s_fp16.mlpackage
    python quantize_kokoro.py --input kokoro.onnx --output kokoro_fp16.mlpackage --from-onnx
"""

import argparse
import os
import sys

try:
    import coremltools as ct
    from coremltools.models.neural_network import quantization_utils
    import numpy as np
except ImportError:
    print("Error: Required packages not installed.")
    print("Run: pip install coremltools numpy")
    sys.exit(1)


def get_model_size_mb(path: str) -> float:
    """Calculate total size of model directory in MB."""
    total = 0
    for dirpath, _, filenames in os.walk(path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            if os.path.isfile(fp):
                total += os.path.getsize(fp)
    return total / (1024 * 1024)


def analyze_model(model_path: str):
    """Analyze model precision and layer types."""
    print(f"\n📊 Analyzing model: {model_path}")
    
    model = ct.models.MLModel(model_path)
    spec = model.get_spec()
    
    # Count layer types
    layer_types = {}
    
    if spec.WhichOneof('Type') == 'neuralNetwork':
        nn = spec.neuralNetwork
        for layer in nn.layers:
            layer_type = layer.WhichOneof('layer')
            layer_types[layer_type] = layer_types.get(layer_type, 0) + 1
        print("  Model type: Neural Network")
    elif spec.WhichOneof('Type') == 'mlProgram':
        print("  Model type: ML Program (MIL-based)")
    
    if layer_types:
        print(f"  Layer breakdown: {layer_types}")
    print(f"  Model size: {get_model_size_mb(model_path):.2f} MB")
    
    return model


def quantize_to_float16(input_path: str, output_path: str) -> dict:
    """
    Quantize CoreML model weights from Float32 to Float16.
    
    Returns metrics dict with before/after sizes.
    """
    print(f"\n🔄 Loading model from: {input_path}")
    model = ct.models.MLModel(input_path)
    
    original_size = get_model_size_mb(input_path)
    print(f"  Original size: {original_size:.2f} MB")
    
    spec = model.get_spec()
    
    if spec.WhichOneof('Type') == 'mlProgram':
        print("\n🔧 Quantizing ML Program to Float16...")
        
        # Use the compression API for ML Programs
        op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="float16"
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        
        quantized_model = ct.optimize.coreml.linear_quantize_weights(
            model, 
            config=config
        )
    else:
        print("\n🔧 Quantizing Neural Network to Float16...")
        # For older Neural Network format
        quantized_model = quantization_utils.quantize_weights(
            model, 
            nbits=16,
            quantization_mode="linear"
        )
    
    # Save quantized model
    print(f"\n💾 Saving quantized model to: {output_path}")
    quantized_model.save(output_path)
    
    quantized_size = get_model_size_mb(output_path)
    reduction = ((original_size - quantized_size) / original_size) * 100
    
    metrics = {
        "original_size_mb": original_size,
        "quantized_size_mb": quantized_size,
        "reduction_percent": reduction
    }
    
    print(f"\n✅ Quantization complete!")
    print(f"  Original:  {original_size:.2f} MB")
    print(f"  Quantized: {quantized_size:.2f} MB")
    print(f"  Reduction: {reduction:.1f}%")
    
    return metrics


def quantize_to_int8(input_path: str, output_path: str) -> dict:
    """
    Quantize CoreML model to Int8 using palettization.
    """
    print(f"\n🔄 Loading model for Int8 quantization: {input_path}")
    model = ct.models.MLModel(input_path)
    
    original_size = get_model_size_mb(input_path)
    
    spec = model.get_spec()
    
    if spec.WhichOneof('Type') == 'mlProgram':
        print("\n🔧 Applying Int8 palettization to ML Program...")
        
        op_config = ct.optimize.coreml.OpPalettizerConfig(
            mode="kmeans",
            nbits=8
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        
        quantized_model = ct.optimize.coreml.palettize_weights(
            model,
            config=config
        )
    else:
        print("\n🔧 Applying 8-bit quantization to Neural Network...")
        quantized_model = quantization_utils.quantize_weights(
            model,
            nbits=8,
            quantization_mode="kmeans"
        )
    
    print(f"\n💾 Saving Int8 model to: {output_path}")
    quantized_model.save(output_path)
    
    quantized_size = get_model_size_mb(output_path)
    reduction = ((original_size - quantized_size) / original_size) * 100
    
    metrics = {
        "original_size_mb": original_size,
        "quantized_size_mb": quantized_size,
        "reduction_percent": reduction
    }
    
    print(f"\n✅ Int8 quantization complete!")
    print(f"  Original:  {original_size:.2f} MB")
    print(f"  Quantized: {quantized_size:.2f} MB")  
    print(f"  Reduction: {reduction:.1f}%")
    
    return metrics


def convert_onnx_to_coreml_fp16(onnx_path: str, output_path: str, min_target: str = "ios16"):
    """
    Convert ONNX model to CoreML with Float16 precision.
    """
    print(f"\n🔄 Converting ONNX to CoreML (Float16): {onnx_path}")
    
    target_map = {
        "ios15": ct.target.iOS15,
        "ios16": ct.target.iOS16,
        "ios17": ct.target.iOS17,
    }
    
    # Define input shapes based on Kokoro architecture
    input_shapes = [
        ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, 512)), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, ct.RangeDim(1, 512)), dtype=np.int32),
        ct.TensorType(name="ref_s", shape=(1, 256), dtype=np.float16),
        ct.TensorType(name="random_phases", shape=(1, 9), dtype=np.float16),
    ]
    
    # Convert with Float16 precision
    model = ct.convert(
        onnx_path,
        inputs=input_shapes,
        minimum_deployment_target=target_map.get(min_target, ct.target.iOS16),
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    
    model.save(output_path)
    print(f"✅ Saved to: {output_path}")
    
    return model


def validate_quantized_model(original_path: str, quantized_path: str):
    """
    Compare outputs of original vs quantized model to measure degradation.
    """
    print("\n🧪 Validating quantized model...")
    
    original = ct.models.MLModel(original_path)
    quantized = ct.models.MLModel(quantized_path)
    
    # Create dummy test input
    test_input = {
        "input_ids": np.zeros((1, 124), dtype=np.int32),
        "attention_mask": np.ones((1, 124), dtype=np.int32),
        "ref_s": np.random.randn(1, 256).astype(np.float32),
        "random_phases": np.zeros((1, 9), dtype=np.float32)
    }
    
    try:
        orig_output = original.predict(test_input)
        quant_output = quantized.predict(test_input)
        
        # Compare audio outputs
        if "audio" in orig_output and "audio" in quant_output:
            orig_audio = np.array(orig_output["audio"]).flatten()
            quant_audio = np.array(quant_output["audio"]).flatten()
            
            min_len = min(len(orig_audio), len(quant_audio))
            orig_audio = orig_audio[:min_len]
            quant_audio = quant_audio[:min_len]
            
            noise = orig_audio - quant_audio
            signal_power = np.mean(orig_audio ** 2)
            noise_power = np.mean(noise ** 2)
            
            if noise_power > 0:
                snr_db = 10 * np.log10(signal_power / noise_power)
            else:
                snr_db = float('inf')
            
            max_error = np.max(np.abs(noise))
            mean_error = np.mean(np.abs(noise))
            
            print(f"  Signal-to-Noise Ratio: {snr_db:.2f} dB")
            print(f"  Max Absolute Error: {max_error:.6f}")
            print(f"  Mean Absolute Error: {mean_error:.6f}")
            
            if snr_db > 40:
                print("  ✅ Quality: Excellent (degradation likely inaudible)")
            elif snr_db > 30:
                print("  ⚠️ Quality: Good (minor degradation possible)")
            else:
                print("  ❌ Quality: Fair (audible degradation likely)")
                
            return {"snr_db": snr_db, "max_error": max_error, "mean_error": mean_error}
            
    except Exception as e:
        print(f"  ⚠️ Validation failed: {e}")
        return None


def compile_for_device(mlpackage_path: str, output_dir: str):
    """
    Compile .mlpackage to .mlmodelc for deployment.
    """
    import subprocess
    
    print(f"\n📦 Compiling to .mlmodelc: {mlpackage_path}")
    
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
        capture_output=True,
        text=True
    )
    
    if result.returncode == 0:
        print(f"  ✅ Compiled to: {output_dir}")
        return True
    else:
        print(f"  ❌ Compilation failed: {result.stderr}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Quantize Kokoro TTS CoreML model"
    )
    parser.add_argument(
        "--input", "-i",
        required=True,
        help="Input model path (.mlpackage, .mlmodelc, or .onnx)"
    )
    parser.add_argument(
        "--output", "-o", 
        required=True,
        help="Output quantized model path"
    )
    parser.add_argument(
        "--precision",
        choices=["float16", "int8"],
        default="float16",
        help="Target precision (default: float16)"
    )
    parser.add_argument(
        "--from-onnx",
        action="store_true",
        help="Input is ONNX format (convert first)"
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate quantized model output quality"
    )
    parser.add_argument(
        "--compile",
        action="store_true", 
        help="Compile output to .mlmodelc"
    )
    parser.add_argument(
        "--target",
        choices=["ios15", "ios16", "ios17"],
        default="ios16",
        help="Minimum deployment target for ONNX conversion"
    )
    
    args = parser.parse_args()
    
    # Handle ONNX conversion
    if args.from_onnx:
        convert_onnx_to_coreml_fp16(args.input, args.output, args.target)
        print("\n🎉 ONNX conversion complete!")
        return
    
    # Analyze original model
    analyze_model(args.input)
    
    # Quantize based on precision choice
    if args.precision == "float16":
        metrics = quantize_to_float16(args.input, args.output)
    else:
        metrics = quantize_to_int8(args.input, args.output)
    
    # Validate if requested
    if args.validate:
        validate_quantized_model(args.input, args.output)
    
    # Compile if requested
    if args.compile and args.output.endswith(".mlpackage"):
        compiled_dir = os.path.dirname(args.output)
        compile_for_device(args.output, compiled_dir)
    
    print("\n🎉 Done!")


if __name__ == "__main__":
    main()

