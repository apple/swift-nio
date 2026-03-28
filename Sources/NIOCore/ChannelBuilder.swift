#if swift(>=5.7)
@resultBuilder public struct ChannelPipelineBuilder<InboundOut, OutboundIn> {
    public static func buildPartialBlock<Handler: ChannelDuplexHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, Handler.OutboundIn> where InboundOut == Handler.InboundIn, OutboundIn == Handler.OutboundOut {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<Handler: ChannelInboundHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, OutboundIn> where InboundOut == Handler.InboundIn {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<Handler: ChannelOutboundHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<InboundOut, Handler.OutboundIn> where OutboundIn == Handler.OutboundOut {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    public static func buildPartialBlock<
        PartialIn, PartialOut,
        Handler: ChannelDuplexHandler
    >(
        accumulated base: ModifiedTypedChannel<PartialIn, PartialOut>,
        next handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, Handler.OutboundIn> where PartialIn == Handler.InboundIn, OutboundIn == Handler.OutboundOut
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<
        PartialIn, PartialOut,
        HandlerInboundOut, HandlerOutboundIn
    >(
        accumulated base: ModifiedTypedChannel<PartialIn, PartialOut>,
        next pipeline: CheckedPipeline<PartialIn, HandlerInboundOut, HandlerOutboundIn, PartialOut>
    ) -> CheckedPipeline<InboundOut, HandlerInboundOut, HandlerOutboundIn, OutboundIn>
    {
        CheckedPipeline<_ ,_, _, _>(handlers: base.handlers + pipeline.handlers)
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<PartialOut, Decoder: ByteToMessageDecoder>(
        accumulated base: ModifiedTypedChannel<ByteBuffer, PartialOut>,
        next decoder: Decoder
    ) -> ModifiedTypedChannel<Decoder.InboundOut, PartialOut> {
        ModifiedTypedChannel<_, _>(
            handlers: base.handlers + [ByteToMessageHandler(decoder)]
        )
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<PartialIn, Encoder: MessageToByteEncoder>(
        accumulated base: ModifiedTypedChannel<PartialIn, ByteBuffer>,
        next encoder: Encoder
    ) -> ModifiedTypedChannel<PartialIn, Encoder.OutboundIn> {
        ModifiedTypedChannel<_, _>(
            handlers: base.handlers + [MessageToByteHandler(encoder)]
        )
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<
        PartialIn, PartialOut,
        Handler: ChannelInboundHandler
    >(
        accumulated base: ModifiedTypedChannel<PartialIn, PartialOut>,
        next handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, PartialOut> where PartialIn == Handler.InboundIn
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<
        PartialIn, PartialOut,
        Handler: ChannelOutboundHandler
    >(
        accumulated base: ModifiedTypedChannel<PartialIn, PartialOut>,
        next handler: Handler
    ) -> ModifiedTypedChannel<PartialIn, Handler.OutboundIn> where PartialOut == Handler.OutboundOut
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
    
    @_disfavoredOverload
    public static func buildFinalResult<Input, Output>(
        _ component: CheckedPipeline<InboundOut, Output, Input, OutboundIn>
    ) -> CheckedPipeline<InboundOut, Output, Input, OutboundIn> {
        component
    }
    
    public static func buildFinalResult<Input, Output>(
        _ component: ModifiedTypedChannel<Output, Input>
    ) -> CheckedPipeline<InboundOut, Output, Input, OutboundIn> {
        CheckedPipeline<_, _, _, _>(handlers: component.handlers)
    }
}

extension ChannelPipelineBuilder {
    public static func buildPartialBlock<Handler: ChannelDuplexHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, Handler.OutboundIn> where Handler.InboundIn == ByteBuffer, Handler.OutboundOut == ByteBuffer, InboundOut == IOData, OutboundIn == IOData
    {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<Handler: ChannelInboundHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, OutboundIn> where Handler.InboundIn == ByteBuffer, InboundOut == IOData {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<Handler: ChannelOutboundHandler>(
        first handler: Handler
    ) -> ModifiedTypedChannel<InboundOut, Handler.OutboundIn> where Handler.OutboundOut == ByteBuffer, OutboundIn == IOData {
        ModifiedTypedChannel<_, _>(handlers: [ handler ])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<
        PartialOut,
        Handler: ChannelInboundHandler
    >(
        accumulated base: ModifiedTypedChannel<IOData, PartialOut>,
        next handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, PartialOut> where Handler.InboundIn == ByteBuffer
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
    
    @_disfavoredOverload
    public static func buildPartialBlock<
        PartialIn,
        Handler: ChannelOutboundHandler
    >(
        accumulated base: ModifiedTypedChannel<PartialIn, IOData>,
        next handler: Handler
    ) -> ModifiedTypedChannel<PartialIn, Handler.OutboundIn> where Handler.OutboundOut == ByteBuffer
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
}

extension ChannelPipelineBuilder {
    public static func buildPartialBlock<
        Handler: ChannelDuplexHandler
    >(
        accumulated base: ModifiedTypedChannel<IOData, IOData>,
        next handler: Handler
    ) -> ModifiedTypedChannel<Handler.InboundOut, Handler.OutboundIn> where Handler.InboundIn == ByteBuffer, Handler.OutboundOut == ByteBuffer
    {
        ModifiedTypedChannel<_, _>(handlers: base.handlers + [handler])
    }
}

public struct CheckedPipeline<InboundIn, InboundOut, OutboundIn, OutboundOut> {
    internal let handlers: [ChannelHandler]
}

public struct ModifiedTypedChannel<In, Out> {
    internal let handlers: [ChannelHandler]
}

public extension ChannelPipeline {
    func addHandlers<
        ChannelOutput, PipelineOutput,
        ChannelInput, PipelineInput
    >(
        reading channelOutput: ChannelOutput.Type,
        writing channelInput: ChannelInput.Type,
        @ChannelPipelineBuilder<ChannelOutput, ChannelInput> buildPipeline: () -> CheckedPipeline<ChannelOutput, PipelineOutput, PipelineInput, ChannelInput>
    ) -> EventLoopFuture<Void> {
        addHandlers(buildPipeline().handlers)
    }
    
    
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    func addHandlers<
        ChannelOutput, PipelineOutput,
        ChannelInput, PipelineInput
    >(
        reading channelOutput: ChannelOutput.Type,
        writing channelInput: ChannelInput.Type,
        @ChannelPipelineBuilder<ChannelOutput, ChannelInput> buildPipeline: () -> CheckedPipeline<ChannelOutput, PipelineOutput, PipelineInput, ChannelInput>
    ) async throws {
        try await addHandlers(
            reading: ChannelOutput.self,
            writing: ChannelInput.self,
            buildPipeline: buildPipeline
        ).get()
    }
}
#endif
