﻿// <auto-generated/>

#nullable enable annotations
#nullable disable warnings

// Suppress warnings about [Obsolete] member usage in generated code.
#pragma warning disable CS0612, CS0618

namespace System.Text.Json.Tests.SourceGenRegressionTests.Net90
{
    public partial class Net90GeneratedContext
    {
        private global::System.Text.Json.Serialization.Metadata.JsonTypeInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>>? _ListDateTimeOffset;
        
        /// <summary>
        /// Defines the source generated JSON serialization contract metadata for a given type.
        /// </summary>
        #nullable disable annotations // Marking the property type as nullable-oblivious.
        public global::System.Text.Json.Serialization.Metadata.JsonTypeInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>> ListDateTimeOffset
        #nullable enable annotations
        {
            get => _ListDateTimeOffset ??= (global::System.Text.Json.Serialization.Metadata.JsonTypeInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>>)Options.GetTypeInfo(typeof(global::System.Collections.Generic.List<global::System.DateTimeOffset>));
        }
        
        private global::System.Text.Json.Serialization.Metadata.JsonTypeInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>> Create_ListDateTimeOffset(global::System.Text.Json.JsonSerializerOptions options)
        {
            if (!TryGetTypeInfoForRuntimeCustomConverter<global::System.Collections.Generic.List<global::System.DateTimeOffset>>(options, out global::System.Text.Json.Serialization.Metadata.JsonTypeInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>> jsonTypeInfo))
            {
                var info = new global::System.Text.Json.Serialization.Metadata.JsonCollectionInfoValues<global::System.Collections.Generic.List<global::System.DateTimeOffset>>
                {
                    ObjectCreator = () => new global::System.Collections.Generic.List<global::System.DateTimeOffset>(),
                    SerializeHandler = ListDateTimeOffsetSerializeHandler
                };
                
                jsonTypeInfo = global::System.Text.Json.Serialization.Metadata.JsonMetadataServices.CreateListInfo<global::System.Collections.Generic.List<global::System.DateTimeOffset>, global::System.DateTimeOffset>(options, info);
                jsonTypeInfo.NumberHandling = null;
            }
        
            jsonTypeInfo.OriginatingResolver = this;
            return jsonTypeInfo;
        }

        // Intentionally not a static method because we create a delegate to it. Invoking delegates to instance
        // methods is almost as fast as virtual calls. Static methods need to go through a shuffle thunk.
        private void ListDateTimeOffsetSerializeHandler(global::System.Text.Json.Utf8JsonWriter writer, global::System.Collections.Generic.List<global::System.DateTimeOffset>? value)
        {
            if (value is null)
            {
                writer.WriteNullValue();
                return;
            }
            
            writer.WriteStartArray();

            for (int i = 0; i < value.Count; i++)
            {
                writer.WriteStringValue(value[i]);
            }

            writer.WriteEndArray();
        }
    }
}
