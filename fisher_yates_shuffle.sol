// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract FisherYatesShuffle {


  constructor() {}

  function shuffle(uint _arraySize, uint _randomWord) pure public returns( uint , uint ){
    uint arraySize = _arraySize;
    uint randomWord = _randomWord;

    uint[] memory arr = new uint[](arraySize);

    uint temp;
    uint r;

    // initialize array values in sequence
    for ( uint i = 0; i < arraySize; i++) {
      arr[i] = i+1;
    }

    // shuffle
    for( uint i = arr.length-1; i > 1; i-- ){
      temp = arr[i];
      r = randomWord % i;
      arr[i] = arr[r];
      arr[r] = temp;
    }


    return( arr[0], arr[arr.length-1] );
  }


}
