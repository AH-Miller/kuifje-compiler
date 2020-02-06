# Kuifje
An imperative language for quantitative information flow. 

## Usage
To run the file, you can use cabal. For example, you can run `Examples\BiasCoin.kf` by using 
```
cabal run Examples\BiasCoin.kf
```
## Syntax 
coming soon

## Example
There are some examples under the drectory of `Examples`

A brief example `Examples\BiasCoin.kf`:
```c
p := uniform [0.3, 0.7];
i := 0;
while i < 2 do 
    result := 0 [p] 1;
    leak result;
    i := i + 1;
od;
```
This example demonstrates that there is a biased coin that you do not know which side bias to. It may 0.7 bias toward the head or 0.3 bias toward the head. By flipping the coin twice and leak the coin flip result, how much information you adversary would know about which way the coin bias toward. 
