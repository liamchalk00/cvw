///////////////////////////////////////////
// dcache (data cache)
//
// Written: ross1728@gmail.com July 07, 2021
//          Implements the L1 data cache
//
// Purpose: Storage for data and meta data.
//
// A component of the Wally configurable RISC-V project.
//
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module dcache
  (input logic clk,
   input logic 		       reset,
   input logic 		       StallM,
   input logic 		       StallWtoDCache,
   input logic 		       FlushM,
   input logic 		       FlushW,

   // cpu side
   input logic [1:0] 	       MemRWM,
   input logic [2:0] 	       Funct3M,
   input logic [6:0] 	       Funct7M,
   input logic [1:0] 	       AtomicM,
   input logic [11:0] 	       MemAdrE, // virtual address, but we only use the lower 12 bits.
   input logic [`PA_BITS-1:0]  MemPAdrM, // physical address
   input logic [11:0] 	       VAdr, // when hptw writes dtlb we use this address to index SRAM.

   input logic [`XLEN-1:0]     WriteDataM,
   output logic [`XLEN-1:0]    ReadDataM,
   output logic 	       DCacheStall,
   output logic 	       CommittedM,
   output logic 	       DCacheMiss,
   output logic 	       DCacheAccess,

   // inputs from TLB and PMA/P
   input logic 		       ExceptionM,
   input logic 		       PendingInterruptM, 
   input logic 		       DTLBMissM,
   input logic 		       ITLBMissF,
   input logic 		       CacheableM,
   input logic 		       DTLBWriteM,
   input logic 		       ITLBWriteF,
   input logic 		       WalkerInstrPageFaultF,
   // from ptw
   input logic 		       SelPTW,
   input logic 		       WalkerPageFaultM, 
   output logic 	       MemAfterIWalkDone,
   // ahb side
   output logic [`PA_BITS-1:0] AHBPAdr, // to ahb
   output logic 	       AHBRead,
   output logic 	       AHBWrite,
   input logic 		       AHBAck, // from ahb
   input logic [`XLEN-1:0]     HRDATA, // from ahb
   output logic [`XLEN-1:0]    HWDATA // to ahb
   );

/*  localparam integer	       BLOCKLEN = 256;
  localparam integer	       NUMLINES = 64;
  localparam integer	       NUMWAYS = 4;
  localparam integer	       NUMREPL_BITS = 3;*/
  localparam integer	       BLOCKLEN = `DCACHE_BLOCKLENINBITS;
  localparam integer	       NUMLINES = `DCACHE_WAYSIZEINBYTES*8/BLOCKLEN;
  localparam integer	       NUMWAYS = `DCACHE_NUMWAYS;
  localparam integer	       NUMREPL_BITS = `DCACHE_REPLBITS; // *** not used

  localparam integer	       BLOCKBYTELEN = BLOCKLEN/8;
  localparam integer	       OFFSETLEN = $clog2(BLOCKBYTELEN);
  localparam integer	       INDEXLEN = $clog2(NUMLINES);
  localparam integer	       TAGLEN = `PA_BITS - OFFSETLEN - INDEXLEN;
  localparam integer	       WORDSPERLINE = BLOCKLEN/`XLEN;
  localparam integer	       LOGWPL = $clog2(WORDSPERLINE);
  localparam integer 	       LOGXLENBYTES = $clog2(`XLEN/8);


  logic [1:0] 		       SelAdrM;
  logic [INDEXLEN-1:0]	       SRAMAdr;
  logic [BLOCKLEN-1:0]	       SRAMWriteData;
  logic [BLOCKLEN-1:0] 	       DCacheMemWriteData;
  logic			       SetValid, ClearValid;
  logic			       SetDirty, ClearDirty;
  logic [BLOCKLEN-1:0] 	       ReadDataBlockWayMaskedM [NUMWAYS-1:0];
  logic [NUMWAYS-1:0]	       WayHit;
  logic			       CacheHit;
  logic [BLOCKLEN-1:0]	       ReadDataBlockM;
  logic [`XLEN-1:0]	       ReadDataBlockSetsM [(WORDSPERLINE)-1:0];
  logic [`XLEN-1:0]	       ReadDataWordM, ReadDataWordMuxM;
  logic [`XLEN-1:0]	       FinalWriteDataM, FinalAMOWriteDataM;
  logic [LOGWPL-1:0] 	       FetchCount, NextFetchCount;
  logic [WORDSPERLINE-1:0]     SRAMWordEnable;

  logic 		       SRAMWordWriteEnableM;
  logic 		       SRAMBlockWriteEnableM;
  logic [NUMWAYS-1:0] 	       SRAMBlockWayWriteEnableM;
  logic 		       SRAMWriteEnable;
  logic [NUMWAYS-1:0] 	       SRAMWayWriteEnable;
  

  logic [NUMWAYS-1:0] 	       VictimWay;
  logic [NUMWAYS-1:0] 	       VictimDirtyWay;
  logic [BLOCKLEN-1:0] 	       VictimReadDataBlockM;
  logic 		       VictimDirty;
  logic 		       SelUncached;
  logic [2**LOGWPL-1:0]	       MemPAdrDecodedW;

  logic [`PA_BITS-1:0] 	       BasePAdrM;
  logic [OFFSETLEN-1:0]        BasePAdrOffsetM;
  logic [`PA_BITS-1:0] 	       BasePAdrMaskedM;  
  logic [TAGLEN-1:0] 	       VictimTagWay [NUMWAYS-1:0];
  logic [TAGLEN-1:0] 	       VictimTag;

  
  logic AnyCPUReqM;
  logic FetchCountFlag;
  logic PreCntEn;
  logic CntEn;
  logic CntReset;
  logic SelEvict;

  logic LRUWriteEn;
  
  // data path

  mux3 #(INDEXLEN)
  AdrSelMux(.d0(MemAdrE[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .d1(MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .d2(VAdr[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .s(SelAdrM),
	    .y(SRAMAdr));


  onehotdecoder #(LOGWPL)
  adrdec(.bin(MemPAdrM[LOGWPL+LOGXLENBYTES-1:LOGXLENBYTES]),
		.decoded(MemPAdrDecodedW));
  

  assign SRAMWordEnable = SRAMBlockWriteEnableM ? '1 : MemPAdrDecodedW;
  

  cacheway #(.NUMLINES(NUMLINES), .BLOCKLEN(BLOCKLEN), .TAGLEN(TAGLEN), .OFFSETLEN(OFFSETLEN), .INDEXLEN(INDEXLEN))
  MemWay[NUMWAYS-1:0](.clk,
	 .reset,
	 .RAdr(SRAMAdr),
	 .MemPAdrM(MemPAdrM[`PA_BITS-1:0]),
	 .WriteEnable(SRAMWayWriteEnable),
	 .WriteWordEnable(SRAMWordEnable),
	 .TagWriteEnable(SRAMBlockWayWriteEnableM), 
	 .WriteData(SRAMWriteData),
	 .SetValid,
	 .ClearValid,
	 .SetDirty,
	 .ClearDirty,
	 .SelEvict,
	 .VictimWay,
	 .ReadDataBlockWayMaskedM,
	 .WayHit,
	 .VictimDirtyWay,
	 .VictimTagWay);

  generate
    if(NUMWAYS > 1) begin
      cacheLRU #(NUMWAYS, INDEXLEN, OFFSETLEN, NUMLINES)
      cacheLRU(.clk, .reset,
	       .WayIn(WayHit),
	       .VictimWay,
	       .MemPAdrM(MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	       .SRAMAdr,
	       .LRUWriteEn);
    end else begin
      assign VictimWay = 1'b1;
    end
  endgenerate

  assign SRAMBlockWayWriteEnableM = SRAMBlockWriteEnableM ? VictimWay : '0;
  
  mux2 #(NUMWAYS) WriteEnableMux(.d0(SRAMWordWriteEnableM ? WayHit : '0),
				 .d1(SRAMBlockWayWriteEnableM),
				 .s(SRAMBlockWriteEnableM),
				 .y(SRAMWayWriteEnable));

  
  
  

  assign CacheHit = |WayHit;
  // ReadDataBlockWayMaskedM is a 2d array of cache block len by number of ways.
  // Need to OR together each way in a bitwise manner.
  // Final part of the AO Mux.
  or_rows #(NUMWAYS, BLOCKLEN) ReadDataAOMux(.a(ReadDataBlockWayMaskedM), .y(ReadDataBlockM));
  or_rows #(NUMWAYS, TAGLEN) VictimTagAOMux(.a(VictimTagWay), .y(VictimTag));  

  assign VictimDirty = | VictimDirtyWay;


  // Convert the Read data bus ReadDataSelectWay into sets of XLEN so we can
  // easily build a variable input mux.
  // *** consider using a limited range shift to do this final muxing.
  genvar index;
  
  generate
    for (index = 0; index < WORDSPERLINE; index++) begin
      assign ReadDataBlockSetsM[index] = ReadDataBlockM[((index+1)*`XLEN)-1: (index*`XLEN)];
    end
  endgenerate

  // variable input mux
  assign ReadDataWordM = ReadDataBlockSetsM[MemPAdrM[$clog2(WORDSPERLINE+`XLEN/8) : $clog2(`XLEN/8)]];


  assign HWDATA = CacheableM ? ReadDataBlockSetsM[FetchCount] : WriteDataM;

  mux2 #(`XLEN) UnCachedDataMux(.d0(ReadDataWordM),
				.d1(DCacheMemWriteData[`XLEN-1:0]),
				.s(SelUncached),
				.y(ReadDataWordMuxM));
  
  // finally swr
  // *** BUG fix HSIZED? why was it this way?
  subwordread subwordread(.HRDATA(ReadDataWordMuxM),
			  .HADDRD(MemPAdrM[2:0]),
			  .HSIZED({Funct3M[2], 1'b0, Funct3M[1:0]}),
			  .HRDATAMasked(ReadDataM));

  generate
    if (`A_SUPPORTED) begin
      logic [`XLEN-1:0] AMOResult;
      amoalu amoalu(.srca(ReadDataM), .srcb(WriteDataM), .funct(Funct7M), .width(Funct3M[1:0]), 
                    .result(AMOResult));
      mux2 #(`XLEN) wdmux(WriteDataM, AMOResult, AtomicM[1], FinalAMOWriteDataM);
    end else
      assign FinalAMOWriteDataM = WriteDataM;
  endgenerate
  

  // write path
  subwordwrite subwordwrite(.HRDATA(ReadDataWordM),
			    .HADDRD(MemPAdrM[2:0]),
			    .HSIZED({Funct3M[2], 1'b0, Funct3M[1:0]}),
			    .HWDATAIN(FinalAMOWriteDataM),
			    .HWDATA(FinalWriteDataM));


  // register the fetch data from the next level of memory.
  generate
    for (index = 0; index < WORDSPERLINE; index++) begin:fetchbuffer
      flopen #(`XLEN) fb(.clk(clk),
			 .en(AHBAck & AHBRead & (index == FetchCount)),
			 .d(HRDATA),
			 .q(DCacheMemWriteData[(index+1)*`XLEN-1:index*`XLEN]));
    end
  endgenerate

  mux2 #(`PA_BITS) BaseAdrMux(.d0(MemPAdrM),
			      .d1({VictimTag, MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN], {{OFFSETLEN}{1'b0}}}),
			      .s(SelEvict),
			      .y(BasePAdrM));

  // if not cacheable the offset bits needs to be sent to the EBU.
  // if cacheable the offset bits are discarded.  $ FSM will fetch the whole block.
  assign BasePAdrOffsetM = CacheableM ? {{OFFSETLEN}{1'b0}} : BasePAdrM[OFFSETLEN-1:0];
  assign BasePAdrMaskedM = {BasePAdrM[`PA_BITS-1:OFFSETLEN], BasePAdrOffsetM};
  
  assign AHBPAdr = ({{`PA_BITS-LOGWPL{1'b0}}, FetchCount} << $clog2(`XLEN/8)) + BasePAdrMaskedM;
  


  mux2 #(BLOCKLEN) WriteDataMux(.d0({WORDSPERLINE{FinalWriteDataM}}),
				.d1(DCacheMemWriteData),
				.s(SRAMBlockWriteEnableM),
				.y(SRAMWriteData));


  localparam FetchCountThreshold = WORDSPERLINE - 1;
  

  assign FetchCountFlag = (FetchCount == FetchCountThreshold[LOGWPL-1:0]);

  flopenr #(LOGWPL) 
  FetchCountReg(.clk(clk),
		.reset(reset | CntReset),
		.en(CntEn),
		.d(NextFetchCount),
		.q(FetchCount));

  assign NextFetchCount = FetchCount + 1'b1;

  assign SRAMWriteEnable = SRAMBlockWriteEnableM | SRAMWordWriteEnableM;


  // control path *** eventually move to own module.
  
  dcachefsm dcachefsm(.clk,
 		      .reset,
		      .MemRWM,
		      .AtomicM,
 		      .ExceptionM,
 		      .PendingInterruptM,
 		      .StallWtoDCache,
 		      .DTLBMissM,
 		      .ITLBMissF,
 		      .CacheableM,
 		      .DTLBWriteM,
 		      .ITLBWriteF,
 		      .WalkerInstrPageFaultF,
 		      .SelPTW,
 		      .WalkerPageFaultM,
 		      .AHBAck, // from ahb
 		      .CacheHit,
 		      .FetchCountFlag,
 		      .VictimDirty,
		      .DCacheStall,
		      .CommittedM,
		      .DCacheMiss,
		      .DCacheAccess,
		      .MemAfterIWalkDone,
		      .AHBRead,
		      .AHBWrite,
		      .SelAdrM,
		      .CntEn,
		      .SetValid,
		      .ClearValid,
		      .SetDirty,
		      .ClearDirty,
		      .SRAMWordWriteEnableM,
		      .SRAMBlockWriteEnableM,
		      .CntReset,
		      .SelUncached,
		      .SelEvict,
		      .LRUWriteEn);
  

endmodule // dcache
