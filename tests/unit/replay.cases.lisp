;;;; REPLAY testset -- record/replay mechanism, deterministic (a mock stands in for the live
;;;; model during the "record" pass). For each case we RECORD a react flow (wrapping a scripted
;;;; mock), then build a REPLAY model from the captured request->response fixtures and run the
;;;; SAME flow: it must reproduce the answer using only the fixtures (no inner model, zero
;;;; misses). This proves the request-keying is correct -- if keys didn't match across passes,
;;;; replay would miss. :drop t instead checks that a MISSING fixture is detected (re-record).
(in-package :ailisp/tests)

(deftestset replay

  ;; a one-tool react flow records + replays identically.
  (:name "react-single-tool-roundtrip"
   :goal "北京今天多少度?"
   :env ((get-weather . (lambda (city) (declare (ignore city)) "26C")))
   :script ("(call (get-weather \"北京\"))" "(done \"北京今天26C\")")
   :max-steps 5 :answer "北京今天26C")

  ;; a two-tool, multi-step flow: each distinct request keys to its own recorded response.
  (:name "react-two-tools-roundtrip"
   :goal "北京和上海哪个热?"
   :env ((get-weather . (lambda (city) (if (string= city "北京") 26 30))))
   :script ("(call (get-weather \"北京\"))" "(call (get-weather \"上海\"))" "(done \"上海更热\")")
   :max-steps 5 :answer "上海更热")

  ;; immediate done (single chat call) still round-trips.
  (:name "react-immediate-done-roundtrip"
   :goal "say hi" :env ((noop . (lambda () nil)))
   :script ("(done \"hi\")") :max-steps 3 :answer "hi")

  ;; with fixtures dropped, replay must DETECT the missing request (so CI says: re-record).
  (:name "missing-fixture-detected"
   :goal "北京今天多少度?"
   :env ((get-weather . (lambda (city) (declare (ignore city)) "26C")))
   :script ("(call (get-weather \"北京\"))" "(done \"北京今天26C\")")
   :max-steps 5 :answer "北京今天26C" :drop t))
