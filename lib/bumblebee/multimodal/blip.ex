defmodule Bumblebee.Multimodal.Blip do
  alias Bumblebee.Shared

  options =
    [
      text_spec: [
        default: nil,
        doc: "the specification of the text model. See `Bumblebee.Text.BlipText` for details"
      ],
      vision_spec: [
        default: nil,
        doc:
          "the specification of the vision model. See `Bumblebee.Vision.BlipVision` for details"
      ],
      projection_size: [
        default: 512,
        doc: "the dimensionality of text and vision projection layers"
      ],
      logit_scale_initial_value: [
        default: 2.6592,
        doc: "the initial value for the scaling layer used to scale similarity logits"
      ]
    ] ++
      Shared.common_options([
        :output_hidden_states,
        :output_attentions
      ])

  @moduledoc """
  The BLIP model for text-image similarity.

  ## Architectures

    * `:for_conditional_generation` - BLIP model with a language
      modeling head

  ## Inputs

    * `"pixel_values"` - `{batch_size, image_size, image_size, num_channels}`

      Featurized image pixel values.

    * `"decoder_input_ids"` - `{batch_size, target_sequence_length}`

      Indices of decoder input sequence tokens in the vocabulary. If not
      present and `"input_ids"` is, it will be generated by shifting
      each token in `"input_ids"` to the right once.

    * `"decoder_attention_mask"` - `{batch_size, target_sequence_length}`

      Mask indicating which decoder tokens to attend to. This is used
      to ignore padding tokens, which are added when processing a batch
      of sequences with different length.

    * `"decoder_position_ids"` - `{batch_size, target_sequence_length}`

      Indices of positions of each decoder input sequence tokens in
      the position embeddings.

    * `"encoder_hidden_state"` - `{batch_size, sequence_length, hidden_size}`

      Last hidden state output from the encoder. This hidden state is
      used in cross-attention blocks in the decoder. If specified, the
      model will skip the image encoding process and use this value
      directly for cross-attentions in the text decoder.

    * `"cache"`

      A container with cached layer results used to speed up sequential
      decoding (autoregression). With cache, certain hidden states are
      taken from the cache, rather than recomputed on every decoding
      pass. The cache should be treated as opaque and initialized with
      `Bumblebee.Text.Generation.init_cache/4`.

  ## Configuration

  #{Shared.options_doc(options)}

  ## References

    * [BLIP: Bootstrapping Language-Image Pre-training for Unified Vision-Language Understanding and Generation](https://arxiv.org/abs/2201.12086)

  """

  defstruct [architecture: :for_conditional_generation] ++ Shared.option_defaults(options)

  @behaviour Bumblebee.ModelSpec
  @behaviour Bumblebee.Configurable
  @behaviour Bumblebee.Text.Generation

  alias Bumblebee.Layers

  @impl true
  def architectures(), do: [:for_conditional_generation]

  @impl true
  def config(spec, opts) do
    Shared.put_config_attrs(spec, opts)
  end

  @impl true
  def input_template(%{vision_spec: vision_spec}) do
    vision_shape = {1, vision_spec.image_size, vision_spec.image_size, vision_spec.num_channels}

    %{
      "pixel_values" => Nx.template(vision_shape, :f32),
      "decoder_input_ids" => Nx.template({1, 1}, :u32)
    }
  end

  @impl true
  def model(%__MODULE__{architecture: :for_conditional_generation} = spec) do
    %{vision_spec: vision_spec, text_spec: text_spec} = spec

    vision_shape = {nil, vision_spec.image_size, vision_spec.image_size, vision_spec.num_channels}
    text_shape = {nil, nil}
    vision_hidden_shape = {nil, nil, vision_spec.hidden_size}

    inputs =
      Bumblebee.Utils.Model.inputs_to_map([
        Axon.input("pixel_values", shape: vision_shape),
        Axon.input("decoder_input_ids", optional: true, shape: text_shape),
        Axon.input("decoder_attention_mask", optional: true, shape: text_shape),
        Axon.input("decoder_position_ids", optional: true, shape: text_shape),
        Axon.input("encoder_hidden_state", optional: true, shape: vision_hidden_shape),
        Axon.input("cache", optional: true)
      ])

    vision_model =
      vision_spec
      |> Bumblebee.configure(
        output_hidden_states: spec.output_hidden_states,
        output_attentions: spec.output_hidden_states
      )
      |> Bumblebee.build_model()
      |> Bumblebee.Utils.Axon.prefix_names("vision_model.")
      |> Bumblebee.Utils.Axon.plug_inputs(%{
        "pixel_values" => inputs["pixel_values"]
      })

    vision_model_outputs =
      Layers.if_present inputs["encoder_hidden_state"] do
        %{
          hidden_state: inputs["encoder_hidden_state"],
          hidden_states: Layers.none(),
          attentions: Layers.none()
        }
      else
        %{
          hidden_state: Axon.nx(vision_model, & &1.hidden_state),
          hidden_states: Axon.nx(vision_model, & &1.hidden_states),
          attentions: Axon.nx(vision_model, & &1.attentions)
        }
      end

    text_decoder =
      text_spec
      |> Bumblebee.configure(
        output_hidden_states: spec.output_hidden_states,
        output_attentions: spec.output_hidden_states
      )
      |> Bumblebee.build_model()
      |> Bumblebee.Utils.Axon.prefix_names("text_decoder.")
      |> Bumblebee.Utils.Axon.plug_inputs(%{
        "input_ids" => inputs["decoder_input_ids"],
        "attention_mask" => inputs["decoder_attention_mask"],
        "position_ids" => inputs["decoder_position_ids"],
        "encoder_hidden_state" => vision_model_outputs.hidden_state,
        "cache" => inputs["cache"]
      })

    Layers.output(%{
      logits: Axon.nx(text_decoder, & &1.logits),
      decoder_hidden_states: Axon.nx(text_decoder, & &1.hidden_states),
      decoder_attentions: Axon.nx(text_decoder, & &1.attentions),
      cross_attentions: Axon.nx(text_decoder, & &1.cross_attentions),
      encoder_hidden_state: vision_model_outputs.hidden_state,
      encoder_hidden_states: vision_model_outputs.hidden_states,
      encoder_attentions: vision_model_outputs.attentions,
      cache: Axon.nx(text_decoder, & &1.cache)
    })
  end

  @impl true
  def init_cache(
        %{vision_spec: vision_spec, text_spec: text_spec},
        batch_size,
        max_length,
        inputs
      ) do
    num_patches = div(vision_spec.image_size, vision_spec.patch_size) ** 2
    encoder_sequence_length = num_patches + 1
    encoder_shape = {batch_size, encoder_sequence_length, text_spec.hidden_size}

    inputs =
      %{
        "input_ids" => inputs["decoder_input_ids"],
        "attention_mask" => inputs["decoder_attention_mask"],
        "position_ids" => inputs["decoder_position_ids"],
        "encoder_hidden_state" => Nx.template(encoder_shape, :f32)
      }
      |> Map.reject(&match?({_, nil}, &1))

    text_spec.__struct__.init_cache(text_spec, batch_size, max_length, inputs)
  end

  @impl true
  def traverse_cache(_spec, cache, fun) do
    Layers.Decoder.traverse_cache(cache, fun)
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    def load(spec, data) do
      import Shared.Converters

      {text_data, data} = Map.pop(data, "text_config", %{})
      {vision_data, data} = Map.pop(data, "vision_config", %{})

      text_spec =
        Bumblebee.Text.BlipText
        |> Bumblebee.configure(architecture: :for_causal_language_modeling)
        |> Bumblebee.HuggingFace.Transformers.Config.load(text_data)

      vision_spec =
        Bumblebee.Vision.BlipVision
        |> Bumblebee.configure()
        |> Bumblebee.HuggingFace.Transformers.Config.load(vision_data)

      opts =
        convert!(data,
          projection_size: {"projection_dim", number()},
          logit_scale_initial_value: {"logit_scale_init_value", number()}
        ) ++ Shared.common_options_from_transformers(data, spec)

      @for.config(spec, opts ++ [text_spec: text_spec, vision_spec: vision_spec])
    end
  end

  defimpl Bumblebee.HuggingFace.Transformers.Model do
    alias Bumblebee.HuggingFace.Transformers

    def params_mapping(spec) do
      text_mapping =
        spec.text_spec
        |> Transformers.Model.params_mapping()
        |> Transformers.Utils.prefix_params_mapping("text_decoder", nil)

      vision_mapping =
        spec.vision_spec
        |> Transformers.Model.params_mapping()
        |> Transformers.Utils.prefix_params_mapping("vision_model", nil)

      %{
        "text_projection" => "text_projection",
        "visual_projection" => "visual_projection",
        "scale" => %{
          "scale" => {[{"scale", "logit_scale"}], fn [scale] -> scale end}
        }
      }
      |> Map.merge(text_mapping)
      |> Map.merge(vision_mapping)
    end
  end
end
