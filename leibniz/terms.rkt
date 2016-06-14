#lang racket

(require "./lightweight-class.rkt"
         "./sorts.rkt"
         "./operators.rkt"
         "./numbers.rkt"
         "./condd.rkt"
         racket/generic
         rackjure/threading
         racket/generator)

(module+ test
  (require rackunit racket/function rackjure/threading)
  ; Define a simple sort graph and signaturefor testing
  (define sorts
    (~> exact-number-sorts
        (add-sort 'A) (add-sort 'B)
        (add-subsort-relation 'B 'A)
        (add-sort 'X) (add-sort 'Y)
        (add-subsort-relation 'Y 'X)))
  (define a-signature
    (~> (empty-signature sorts)
        (add-op 'an-A empty 'A)
        (add-op 'a-B empty 'B)
        (add-op 'an-X empty 'X)
        (add-op 'a-Y empty 'Y)
        (add-op 'foo empty 'B)
        (add-op 'foo (list 'B) 'A)
        (add-op 'foo (list 'A 'B) 'A))))

;
; The generic interface for terms
;
(define-generics term
  [term.sort term]
  [term.signature term]
  [term.has-vars? term]
  #:fast-defaults
  ([number?
    (define term.sort number-term.sort)
    (define term.signature number-term.signature)
    (define (term.has-vars? x) #f)])
  #:fallbacks
  [(define (term.has-vars? x) #f)])

(module+ test
  (check-equal? (term.sort 0) 'Zero)
  (check-equal? (term.sort 1) 'NonZeroNatural)
  (check-equal? (term.sort -1) 'NonZeroInteger)
  (check-equal? (term.sort 1/2) 'PositiveRational)
  (check-equal? (term.sort -1/2) 'NonZeroRational)
  (check-equal? (term.signature 0) integer-signature)
  (check-equal? (term.signature 1/2) exact-number-signature)
  (check-false (term.has-vars? 1)))

;
; Substitutions are var->term hashes describing a match.
; Combining two substitutions that are contradictory leads to
; a non-match signalled by the special value #f.
;
(define empty-substitution (hash))

(define (substitution var term)
  (hash var term))

(define (merge-substitutions s1 s2)
  (if (not s2)
      #f
      (for/fold ([s-acc s1])
                ([(var value) s2])
        #:break (not s-acc)
        (if (and (hash-has-key? s-acc var)
                 (not (equal? (hash-ref s-acc var) value)))
            #f
            (hash-set s-acc var value)))))

(define (substitution-value substitution var)
  (hash-ref substitution var #f))

(module+ test
  ; Substitutions are meant to be used as var->term mappings,
  ; but they are really just hash maps with special key collision
  ; handling. The tests use symbol keys for simplicity.
  (check-equal? (merge-substitutions (substitution 'A 1)
                                     (substitution 'B 2))
                (hash 'A 1 'B 2))
  (check-equal? (merge-substitutions
                 (merge-substitutions (substitution 'A 1)
                                      (substitution 'B 2))
                 (substitution 'C 3))
                (hash 'A 1 'B 2 'C 3))
  (check-false (merge-substitutions (substitution 'A 1)
                                    (substitution 'A 2)))
  (check-false (merge-substitutions #f (substitution 'A 2)))
  (check-false (merge-substitutions (substitution 'A 2) #f))
  (check-equal? (substitution-value
                 (merge-substitutions (substitution 'A 1)
                                      (substitution 'B 2))
                 'B) 2)
  (check-false (substitution-value
                (merge-substitutions (substitution 'A 1)
                                     (substitution 'B 2))
                'C)))

;
; Matching returns a sequence of all match-generating substitutions.
;
(define no-match empty-sequence)

(define (single-match substitution)
  (in-value substitution))

(define-syntax-rule (conditional-match pred? substitution)
  (if pred?
      (single-match substitution)
      no-match))

;
; The generic interface for patterns
; Non-pattern term data types implement trivial versions
; of its methods, in which matching is an equality test
; and substitution does nothing.
;
(define (non-pattern-match signature term1 term2)
  (conditional-match (equal? term1 term2) empty-substitution))

(define (non-pattern-substitute signature term substitution)
  term)

(define-generics pattern
  [pattern.match signature pattern term]
  [pattern.substitute signature pattern substitution]
  #:fast-defaults
  ([number?
    (define pattern.match non-pattern-match)
    (define pattern.substitute non-pattern-substitute)])
  #:fallbacks
  [(define pattern.match non-pattern-match)
   (define pattern.substitute non-pattern-substitute)])

(define (all-matches signature pattern term)
  (sequence->list (pattern.match signature pattern term)))

(module+ test
  (define-simple-check (check-no-match signature pattern term)
    (= 0 (sequence-length (pattern.match signature pattern term))))
  (define-simple-check (check-single-match signature pattern term substitution)
    (equal? (all-matches signature pattern term) (list substitution)))
  (define-simple-check (check-self-substitution signature pattern term)
    (equal? (pattern.substitute signature pattern
                                (first (all-matches signature pattern term)))
            term))
  (define-simple-check (check-no-substitution signature pattern)
    (equal? (pattern.substitute signature pattern
                                (substitution
                                 (make-var a-varset 'StrangelyNamedVar)
                                 0))
            pattern)))

(module+ test
  (check-single-match a-signature 1 1 empty-substitution)
  (check-no-match a-signature 0 1))

;
; Operator-defined terms
;
(struct op-term (signature op args sort)
  #:transparent
  #:methods gen:term
  [(define (term.sort t)
     (op-term-sort t))
   (define (term.signature t)
     (op-term-signature t))]
  #:methods gen:pattern [])

(module+ test
  (define an-A (make-term a-signature 'an-A empty))
  (check-equal? (term.sort an-A) 'A)
  (check-false (term.has-vars? an-A))
  (define a-B (make-term a-signature 'a-B empty))
  (check-equal? (term.sort a-B) 'B)
  (check-false (term.has-vars? a-B))
  (define an-X (make-term a-signature 'an-X empty))
  (check-equal? (term.sort an-X) 'X)
  (check-false (term.has-vars? an-X))
  (define a-Y (make-term a-signature 'a-Y empty))
  (check-equal? (term.sort a-Y) 'Y)
  (check-false (term.has-vars? a-Y))
 
  (check-equal? (term.sort (make-term a-signature 'foo empty)) 'B)
  (check-equal? (term.sort (make-term a-signature 'foo (list a-B))) 'A)
  (check-equal? (term.sort (make-term a-signature 'foo (list an-A a-B))) 'A)
  (check-equal? (term.sort (make-term a-signature 'foo (list a-B a-B))) 'A)
  (check-equal? (term.sort (make-term a-signature 'foo (list an-A)))
                (kind sorts 'A))
  (check-equal? (term.sort (make-term a-signature 'foo (list an-A an-A)))
                (kind sorts 'A))
  (check-false (make-term a-signature 'foo (list an-X)))

  (check-single-match a-signature
                      (make-term a-signature 'foo (list a-B))
                      (make-term a-signature 'foo (list a-B))
                      empty-substitution)
  (check-no-match a-signature
                  (make-term a-signature 'foo (list a-B))
                  (make-term a-signature 'foo empty)))

;
; Varsets
;
(define-class varset 

  (field signature vars)

  (define (add-var symbol sort-or-kind)
        (when (hash-has-key? vars symbol)
          (error (format "symbol ~a already used")))
        (validate-sort-constraint (signature-sort-graph signature) sort-or-kind)
        (varset signature
                (hash-set vars symbol sort-or-kind)))

  (define (lookup-var symbol)
    (hash-ref vars symbol #f)))

(define (empty-varset signature)
  (varset signature (hash)))

(module+ test
  (define some-varset
    (~> (empty-varset a-signature)
        (add-var 'X 'A)))
  (check-equal? (lookup-var some-varset 'X) 'A)
  (check-false (lookup-var some-varset 'foo))
  (check-exn exn:fail? (thunk (add-var some-varset 'X 'X)))
  (check-exn exn:fail? (thunk (add-var some-varset 'Z 'Z))))

;
; Variables
;
(struct var (signature name sort-or-kind)
  #:transparent
  #:methods gen:term
  [(define (term.sort t)
     (var-sort-or-kind t))
   (define (term.signature t)
     (var-signature t))
   (define (term.has-vars? t)
     #t)]
  #:methods gen:pattern
  [(define (pattern.match signature pattern term)
     (conditional-match (conforms-to? (signature-sort-graph signature)
                                      (term.sort term)
                                      (var-sort-or-kind pattern))
                        (substitution pattern term)))
   (define (pattern.substitute signature pattern substitution)
     (define value (substitution-value substitution pattern))
     (if value
         value
         pattern))])

(define (make-var varset symbol)
  (define sort-or-kind (lookup-var varset symbol))
  (and sort-or-kind
       (var (varset-signature varset) symbol sort-or-kind)))

(module+ test
  (define a-varset
    (~> (empty-varset a-signature)
        (add-var 'A-var 'A)
        (add-var 'B-var 'B)
        (add-var 'Zero-var 'Zero)
        (add-var 'Integer-var 'Integer)
        (add-var 'NonZeroInteger-var 'NonZeroInteger)
        (add-var 'StrangelyNamedVar 'Zero)))
  (define A-var (make-var a-varset 'A-var))
  (define B-var (make-var a-varset 'B-var))
  (define Zero-var (make-var a-varset 'Zero-var))
  (define Integer-var (make-var a-varset 'Integer-var))
  (define NonZeroInteger-var (make-var a-varset 'NonZeroInteger-var))
  (check-true (term.has-vars? A-var))
  (check-true (term.has-vars? Zero-var))
  (check-true (term.has-vars? Integer-var))
  (check-single-match a-signature Zero-var 0
                      (substitution Zero-var 0))
  (check-single-match a-signature Integer-var 0
                      (substitution Integer-var 0))
  (check-no-match a-signature NonZeroInteger-var 0)
  (check-self-substitution a-signature Zero-var 0)
  (check-no-substitution a-signature Zero-var))

;
; Operator-defined patterns
; An op-pattern is a special case of an op-term that can contain
; variables.
;
(struct op-pattern op-term ()
  #:transparent
  #:methods gen:term
  [(define (term.sort t)
     (op-term-sort t))
   (define (term.signature t)
     (op-term-signature t))
   (define (term.has-vars? t)
     #t)]
  #:methods gen:pattern
  [(define/generic generic-match pattern.match)
   (define (pattern.match signature pattern term)
     (define (match-args p-args t-args substitution)
       (if (empty? p-args)
           (conditional-match substitution substitution)
           (in-generator
            (for ([sf (generic-match signature (first p-args) (first t-args))])
              (let ([sm (merge-substitutions substitution sf)])
                (when sm
                  (for ([s (match-args (rest p-args) (rest t-args) sm)])
                    (yield s))))))))
     (condd
      [(or (not (op-term? term))
           (not (equal? (op-term-op pattern) (op-term-op term))))
       no-match]
      #:do (define p-args (op-term-args pattern))
      #:do (define t-args (op-term-args term))
      [(not (equal? (length p-args) (length t-args)))
       no-match]
      [else
       (match-args p-args t-args empty-substitution)]))

   (define/generic generic-substitute pattern.substitute)
   (define (pattern.substitute signature pattern substitution)
     (make-term signature
                (op-term-op pattern)
                (for/list ([arg (op-term-args pattern)])
                  (generic-substitute signature arg substitution))))])

(module+ test
  (define a-one-var-pattern (make-term a-signature 'foo (list B-var)))
  (check-equal? (term.sort a-one-var-pattern) 'A)
  (check-true (term.has-vars? a-one-var-pattern))
  (check-single-match a-signature a-one-var-pattern
                      (make-term a-signature 'foo (list a-B))
                      (substitution B-var a-B))
  (check-no-match a-signature a-one-var-pattern
                  (make-term a-signature 'foo (list an-A)))

  (define a-two-var-pattern (make-term a-signature 'foo (list A-var B-var)))
  (check-equal? (term.sort a-two-var-pattern) 'A)
  (check-true (term.has-vars? a-two-var-pattern))
  (check-single-match a-signature a-two-var-pattern
                      (make-term a-signature 'foo (list an-A a-B))
                      (merge-substitutions
                       (substitution B-var a-B)
                       (substitution A-var an-A)))
  (check-single-match a-signature a-two-var-pattern
                      (make-term a-signature 'foo (list a-B a-B))
                      (merge-substitutions
                       (substitution B-var a-B)
                       (substitution A-var a-B)))

  (define a-double-var-pattern (make-term a-signature 'foo (list B-var B-var)))
  (define foo0 (make-term a-signature 'foo empty))
  (check-equal? (term.sort a-double-var-pattern) 'A)
  (check-true (term.has-vars? a-double-var-pattern))
  (check-single-match a-signature a-double-var-pattern
                      (make-term a-signature 'foo (list a-B a-B))
                      (substitution B-var a-B))
  (check-single-match a-signature a-double-var-pattern
                      (make-term a-signature 'foo (list foo0 foo0))
                      (substitution B-var foo0))
  (check-no-match a-signature a-double-var-pattern
                  (make-term a-signature 'foo (list a-B foo0)))
  (check-self-substitution a-signature
                           a-double-var-pattern
                           (make-term a-signature 'foo (list a-B a-B)))
  (check-no-substitution a-signature a-double-var-pattern))

;
; Make a variable or an operator-defined term. The result is a pattern
; if any of the arguments is a pattern.
;
(define (make-term signature name args)
  (for ([arg args])
    (unless (equal? (term.signature arg) signature)
      (error "argument has wrong signature")))
  (define sort-or-rank (lookup-op signature name (map term.sort args)))
  (and sort-or-rank
       (if (ormap term.has-vars? args)
           (op-pattern signature name args (cdr sort-or-rank))
           (op-term signature name args (cdr sort-or-rank)))))