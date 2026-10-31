`timescale 1ns/1ps
// Candidate owner 2 of voice_interaction_bus. Speech-only coalescing never
// acknowledges, removes or changes an exam event / risk / evidence transaction.
// Requests are held; accepted old writes must still drain with their old labels.
module voice_notice_queue #(
    parameter integer NOTICE_TTL_S=45,
    parameter integer REPEAT_COOLDOWN_S=0,
    parameter integer SPEAK_SELFTEST=0
) (
    input wire clk,rst,tick_1s,
    input wire [31:0] round_id,
    input wire [63:0] info_tag,
    input wire status_valid,
    input wire [2:0] stage_id,
    input wire submitted_by_timeout,
    // Independent pulses: no-verify, not-authorised, phone, notes, head,
    // camera-blocked, stillness. Caller must not use only the last event code.
    input wire [6:0] event_pulses,
    // Global audio arbiter grants a slot; not an audio-complete signal.
    input wire dispatch_enable,
    output wire req_valid,
    input wire req_ready,
    output wire [7:0] req_type,
    output reg [7:0] req_id,
    output reg [31:0] req_cookie,req_round,
    output reg [63:0] req_tag,
    input wire done_valid,
    input wire [31:0] done_cookie,done_round,
    input wire [63:0] done_tag,
    input wire [1:0] done_error,
    output wire [6:0] pending_events,
    output reg [31:0] coalesced_count,expired_count,cancelled_count,failed_count,
    output reg exhausted
);
    localparam [1:0] IDLE=0,OFFER=1,INFLIGHT=2;
    localparam integer AGE_W=NOTICE_TTL_S<2 ? 1 : $clog2(NOTICE_TTL_S+1);
    localparam integer COOL_W=REPEAT_COOLDOWN_S<2 ? 1 : $clog2(REPEAT_COOLDOWN_S+1);
    reg [1:0] phase;
    reg [31:0] bound_round,cookie_counter;
    reg [63:0] bound_tag;
    reg stage_known,stage_pending;
    reg [2:0] observed_stage,offered_stage;
    reg [7:0] stage_announcement;
    reg [6:0] pending;
    reg [AGE_W-1:0] age[0:6],offer_age;
    reg [COOL_W-1:0] cooldown[0:6];
    reg offered_alarm;
    reg [2:0] alarm_index;
    reg found;
    reg [2:0] selected,next_alarm;
    integer i,k,index,merged,expired;
    wire binding_ok=bound_round==round_id && bound_tag==info_tag;
    wire stage_change=status_valid && (!stage_known || stage_id!=observed_stage);
    wire [2:0] current_stage=status_valid ? stage_id : observed_stage;
    wire offer_expired=offered_alarm && (offer_age>=NOTICE_TTL_S ||
                                      (tick_1s && offer_age>=NOTICE_TTL_S-1));
    wire offer_current=binding_ok && stage_known && current_stage==offered_stage && !offer_expired;
    assign req_valid=!rst && phase==OFFER && offer_current && dispatch_enable;
    assign req_type=8'hff;
    assign pending_events=pending;

    function [7:0] stage_word;
        input [2:0] stage;
        input timeout_submit;
        begin
            case(stage)
                0:stage_word=SPEAK_SELFTEST ? 8'h20 : 8'h00;
                1:stage_word=8'h21;
                // FF40 from the information controller replaces old FF22.
                2:stage_word=8'h00;
                3:stage_word=8'h23;
                4:stage_word=timeout_submit ? 8'h26 : 8'h24;
                5:stage_word=8'h25;
                default:stage_word=8'h00;
            endcase
        end
    endfunction
    function [7:0] alarm_word;
        input [2:0] alarm;
        begin
            case(alarm)
                0:alarm_word=8'h30; 1:alarm_word=8'h31;
                2:alarm_word=8'h32; 3:alarm_word=8'h33;
                4:alarm_word=8'h36; 5:alarm_word=8'h37;
                default:alarm_word=8'h38;
            endcase
        end
    endfunction
    function allowed;
        input [2:0] alarm,stage;
        begin
            allowed=(alarm<2) ? (stage==1 || stage==2) : stage==3;
        end
    endfunction
    function [31:0] sat_add;
        input [31:0] value;
        input integer amount;
        begin sat_add=(value>32'hffffffff-amount) ? 32'hffffffff : value+amount;end
    endfunction
    always @* begin
        found=0;selected=0;
        for(k=0;k<7;k=k+1) begin
            index=next_alarm+k;
            if(index>=7) index=index-7;
            if(!found && pending[index] && allowed(index,observed_stage) &&
               age[index]<NOTICE_TTL_S && cooldown[index]==0 &&
               !(tick_1s && age[index]>=NOTICE_TTL_S-1)) begin
                found=1;selected=index;
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            phase<=IDLE;bound_round<=0;bound_tag<=0;cookie_counter<=0;
            stage_known<=0;stage_pending<=0;observed_stage<=0;offered_stage<=0;
            stage_announcement<=0;pending<=0;next_alarm<=0;
            offer_age<=0;offered_alarm<=0;alarm_index<=0;
            req_id<=0;req_cookie<=0;req_round<=0;req_tag<=0;
            coalesced_count<=0;expired_count<=0;cancelled_count<=0;failed_count<=0;exhausted<=0;
            for(i=0;i<7;i=i+1) begin age[i]<=0;cooldown[i]<=0;end
        end else begin
            // Old accepted transaction drains even when the caller changes round.
            if(phase==INFLIGHT && done_valid && done_cookie==req_cookie &&
               done_round==req_round && done_tag==req_tag) begin
                phase<=IDLE;
                if(done_error!=0) failed_count<=sat_add(failed_count,1);
            end
            if(!binding_ok) begin
                bound_round<=round_id;bound_tag<=info_tag;
                stage_known<=0;stage_pending<=0;pending<=0;
                for(i=0;i<7;i=i+1) begin age[i]<=0;cooldown[i]<=0;end
                if(phase==OFFER) begin phase<=IDLE;cancelled_count<=sat_add(cancelled_count,1);end
            end else begin
                merged=0;expired=0;
                if(stage_change) begin
                    observed_stage<=stage_id;stage_known<=1;
                    stage_announcement<=stage_word(stage_id,submitted_by_timeout);
                    stage_pending<=stage_word(stage_id,submitted_by_timeout)!=0;
                end
                for(i=0;i<7;i=i+1) begin
                    if(tick_1s && cooldown[i]!=0) cooldown[i]<=cooldown[i]-1'b1;
                    if(stage_change) begin pending[i]<=0;age[i]<=0;end
                    else if(tick_1s && pending[i]) begin
                        if(age[i]>=NOTICE_TTL_S-1) begin
                            pending[i]<=0;expired=expired+1;
                        end else age[i]<=age[i]+1'b1;
                    end
                    if(event_pulses[i] && (stage_known || status_valid) && allowed(i,current_stage)) begin
                        // Fresh events during playback retain one follow-up notice.
                        // A repeated pulse never refreshes the age of a queued
                        // notice; continuous activity cannot keep old speech alive.
                        if(cooldown[i]!=0 || (pending[i] && !stage_change) ||
                           (phase==OFFER && offered_alarm && alarm_index==i && !stage_change)) merged=merged+1;
                        else begin pending[i]<=1;age[i]<=0;end
                    end
                end
                if(merged!=0) coalesced_count<=sat_add(coalesced_count,merged);
                if(expired!=0) expired_count<=sat_add(expired_count,expired);
                if(phase==OFFER) begin
                    if(tick_1s && !offer_expired) offer_age<=offer_age+1'b1;
                    if(!offer_current) begin
                        phase<=IDLE;cancelled_count<=sat_add(cancelled_count,1);
                        if(offer_expired) expired_count<=sat_add(expired_count,expired+1);
                    end else if(req_valid && req_ready) begin
                        phase<=INFLIGHT;
                        if(offered_alarm) cooldown[alarm_index]<=REPEAT_COOLDOWN_S;
                    end
                end
                // New stage always wins over selection of old pending speech.
                if(phase==IDLE && dispatch_enable && !stage_change && stage_known &&
                   (stage_pending || found) && !exhausted) begin
                    if(cookie_counter==32'hffffffff) exhausted<=1;
                    else begin
                        cookie_counter<=cookie_counter+1'b1;req_cookie<=cookie_counter+1'b1;
                        req_round<=round_id;req_tag<=info_tag;offered_stage<=observed_stage;
                        phase<=OFFER;
                        if(stage_pending) begin
                            req_id<=stage_announcement;stage_pending<=0;offered_alarm<=0;offer_age<=0;
                        end
                        else begin
                            req_id<=alarm_word(selected);pending[selected]<=0;
                            offered_alarm<=1;alarm_index<=selected;offer_age<=age[selected]+tick_1s;
                            next_alarm<=selected==6 ? 0 : selected+1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
