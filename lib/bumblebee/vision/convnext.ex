defmodule Bumblebee.Vision.ConvNext do
  @common_keys [:id2label, :label2id, :num_labels, :output_hidden_states]

  @moduledoc """
  Models based on the ConvNeXT architecture.

  ## Architectures

    * `:base` - plain ConvNeXT without any head on top

    * `:for_image_classification` - ConvNeXT with a classification head.
      The head consists of a single dense layer on top of the pooled
      features

  ## Inputs

    * `"pixel_values"` - featurized image pixel values in NCHW format (224x224)

  ## Configuration

    * `:num_channels` - the number of input channels. Defaults to `3`

    * `:patch_size` - patch size to use in the embedding layer. Defaults
      to `4`

    * `:num_stages` - the number of stages of the model. Defaults to `4`

    * `:hidden_sizes` - dimensionality (hidden size) at each stage.
      Defaults to `[96, 192, 384, 768]`

    * `:depths` - depth (number of layers) for each stage. Defaults
      to `[3, 3, 9, 3]`

    * `:hidden_act` - the activation function in each block. Defaults
      to `:gelu`

    * `:initializer_range` - standard deviation of the truncated normal
      initializer for initializing weight matrices. Defaults to `0.02`

    * `:layer_norm_eps` - epsilon value used by layer normalization layers.
      Defaults to `1.0e-12`

    * `:layer_scale_init_value` - initial value for layer normalization scale.
      Defaults to `1.0e-6`

    * `:drop_path_rate` - drop path rate for stochastic depth. Defaults to
      `0.0`

  ### Common Options

  #{Bumblebee.Shared.common_config_docs(@common_keys)}

  ## References

    * [A ConvNet for the 2020s](https://arxiv.org/abs/2201.03545)
  """

  import Bumblebee.Utils.Model, only: [join: 2]

  alias Bumblebee.Shared
  alias Bumblebee.Layers

  defstruct [
              architecture: :base,
              num_channels: 3,
              patch_size: 4,
              num_stages: 4,
              hidden_sizes: [96, 192, 384, 768],
              depths: [3, 3, 9, 3],
              hidden_act: :gelu,
              initializer_range: 0.02,
              layer_norm_eps: 1.0e-12,
              layer_scale_init_value: 1.0e-6,
              drop_path_rate: 0.0
            ] ++ Shared.common_config_defaults(@common_keys)

  @behaviour Bumblebee.ModelSpec

  @impl true
  def architectures(), do: [:base, :for_image_classification]

  @impl true
  def base_model_prefix(), do: "convnext"

  @impl true
  def config(config, opts \\ []) do
    opts = Shared.add_common_computed_options(opts)
    Shared.put_config_attrs(config, opts)
  end

  @impl true
  def input_template(config) do
    %{
      "pixel_values" => Nx.template({1, config.num_channels, 224, 224}, :f32)
    }
  end

  @impl true
  def model(%__MODULE__{architecture: :base} = config) do
    config
    |> convnext()
    |> Layers.output()
  end

  def model(%__MODULE__{architecture: :for_image_classification} = config) do
    outputs = convnext(config, name: "convnext")

    logits =
      outputs.pooler_output
      |> Axon.dense(config.num_labels,
        name: "classifier",
        kernel_initializer: kernel_initializer(config)
      )

    Layers.output(%{logits: logits, hidden_states: outputs.hidden_states})
  end

  defp convnext(config, opts \\ []) do
    name = opts[:name]

    pixel_values = Axon.input("pixel_values", shape: {nil, config.num_channels, 224, 224})

    embedding_output = embeddings(pixel_values, config, name: join(name, "embeddings"))

    encoder_output = encoder(embedding_output, config, name: join(name, "encoder"))

    pooled_output =
      encoder_output.last_hidden_state
      |> Axon.global_avg_pool()
      |> Axon.layer_norm(
        epsilon: config.layer_norm_eps,
        name: join(name, "layernorm"),
        beta_initializer: :zeros,
        gamma_initializer: :ones
      )

    %{
      last_hidden_state: encoder_output.last_hidden_state,
      pooler_output: pooled_output,
      hidden_states: encoder_output.hidden_states
    }
  end

  defp embeddings(%Axon{} = pixel_values, config, opts) do
    name = opts[:name]
    [embedding_size | _] = config.hidden_sizes

    pixel_values
    |> Axon.conv(embedding_size,
      kernel_size: config.patch_size,
      strides: config.patch_size,
      name: join(name, "patch_embeddings"),
      kernel_initializer: kernel_initializer(config)
    )
    |> Axon.layer_norm(
      epsilon: 1.0e-6,
      name: join(name, "layernorm"),
      beta_initializer: :zeros,
      gamma_initializer: :ones
    )
  end

  defp encoder(hidden_state, config, opts) do
    name = opts[:name]

    drop_path_rates = get_drop_path_rates(config.depths, config.drop_path_rate)

    stages =
      Enum.zip([0..(config.num_stages - 1), config.depths, drop_path_rates, config.hidden_sizes])

    state = %{
      last_hidden_state: hidden_state,
      hidden_states: Layers.maybe_container({hidden_state}, config.output_hidden_states),
      in_channels: hd(config.hidden_sizes)
    }

    for {idx, depth, drop_path_rates, out_channels} <- stages, reduce: state do
      state ->
        strides = if idx > 0, do: 2, else: 1

        hidden_state =
          conv_next_stage(
            state.last_hidden_state,
            state.in_channels,
            out_channels,
            config,
            strides: strides,
            depth: depth,
            drop_path_rates: drop_path_rates,
            name: name |> join("stages") |> join(idx)
          )

        %{
          last_hidden_state: hidden_state,
          hidden_states: Layers.append(state.hidden_states, hidden_state),
          in_channels: out_channels
        }
    end
  end

  defp conv_next_stage(hidden_state, in_channels, out_channels, config, opts) do
    name = opts[:name]

    strides = opts[:strides]
    depth = opts[:depth]
    drop_path_rates = opts[:drop_path_rates]

    downsampled =
      if in_channels != out_channels or strides > 1 do
        hidden_state
        |> Axon.layer_norm(
          epsilon: 1.0e-6,
          name: join(name, "downsampling_layer.0"),
          beta_initializer: :zeros,
          gamma_initializer: :ones
        )
        |> Axon.conv(out_channels,
          kernel_size: 2,
          strides: strides,
          name: join(name, "downsampling_layer.1"),
          kernel_initializer: kernel_initializer(config)
        )
      else
        hidden_state
      end

    # Ensure the rates have been computed properly
    ^depth = length(drop_path_rates)

    for {drop_path_rate, idx} <- Enum.with_index(drop_path_rates), reduce: downsampled do
      x ->
        conv_next_layer(x, out_channels, config,
          name: name |> join("layers") |> join(idx),
          drop_path_rate: drop_path_rate
        )
    end
  end

  defp conv_next_layer(%Axon{} = hidden_state, out_channels, config, opts) do
    name = opts[:name]

    drop_path_rate = opts[:drop_path_rate]

    input = hidden_state

    x =
      hidden_state
      |> Axon.depthwise_conv(1,
        kernel_size: 7,
        padding: [{3, 3}, {3, 3}],
        name: join(name, "dwconv"),
        kernel_initializer: kernel_initializer(config)
      )
      |> Axon.transpose([0, 2, 3, 1], ignore_batch?: false, name: join(name, "transpose1"))
      |> Axon.layer_norm(
        epsilon: 1.0e-6,
        channel_index: 3,
        name: join(name, "layernorm"),
        beta_initializer: :zeros,
        gamma_initializer: :ones
      )
      |> Axon.dense(4 * out_channels,
        name: join(name, "pwconv1"),
        kernel_initializer: kernel_initializer(config)
      )
      |> Axon.activation(config.hidden_act, name: join(name, "activation"))
      |> Axon.dense(out_channels,
        name: join(name, "pwconv2"),
        kernel_initializer: kernel_initializer(config)
      )

    scaled =
      if config.layer_scale_init_value > 0 do
        Layers.scale(x,
          name: name,
          scale_init_value: config.layer_scale_init_value,
          scale_name: "layer_scale_parameter",
          channel_index: 3
        )
      else
        x
      end

    scaled
    |> Axon.transpose([0, 3, 1, 2], ignore_batch?: false, name: join(name, "transpose2"))
    |> Layers.drop_path(rate: drop_path_rate, name: join(name, "drop_path"))
    |> Axon.add(input, name: join(name, "residual"))
  end

  defp get_drop_path_rates(depths, rate) do
    sum_of_depths = Enum.sum(depths)

    rates =
      Nx.iota({sum_of_depths})
      |> Nx.multiply(rate / sum_of_depths - 1)
      |> Nx.to_flat_list()

    {final_rates, _} =
      Enum.map_reduce(depths, rates, fn depth, rates ->
        Enum.split(rates, depth)
      end)

    final_rates
  end

  defp kernel_initializer(config) do
    Axon.Initializers.normal(scale: config.initializer_range)
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    def load(config, data) do
      data
      |> Shared.convert_to_atom(["hidden_act"])
      |> Shared.convert_common()
      |> Shared.data_into_config(config, except: [:architecture])
    end
  end
end